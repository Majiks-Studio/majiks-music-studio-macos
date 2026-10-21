"""ACE-Step gate: the 3090 music generator for remote Majiks Music Studio clients.

Speaks the subset of the Majiks studio API the Mac app's Remote mode calls
(/api/v1/studio/generate, /jobs/{id}, /jobs/{id}/audio, /jobs/{id}/save, /health)
and translates it to ACE-Step's native API on a localhost port. Nothing else of
ACE-Step (training, dataset, LoRA routes) is reachable through it.

- Per-person keys: keys.json holds sha256 hashes + name + expiry. Never values.
  Manage them with gate_keys.py.
- On demand: the first job starts ACE-Step on the 3090.
- Idle unload: after GATE_IDLE_SECONDS with no requests and no unfinished jobs,
  the gate stops the ACE-Step process it started. One it did not start (another
  service already on the backend port) is used but never stopped.

All settings come from environment variables (see gate.env.example).
"""

import asyncio
import datetime as dt
import hashlib
import hmac
import json
import logging
import os
import signal
import subprocess
import time
import uuid
from pathlib import Path

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response

GATE_DIR = Path(__file__).resolve().parent
KEYS_FILE = Path(os.getenv("GATE_KEYS_FILE", GATE_DIR / "keys.json"))
ACE_PORT = int(os.getenv("GATE_ACE_PORT", "8020"))
BACKEND = f"http://127.0.0.1:{ACE_PORT}"
IDLE_SECONDS = int(os.getenv("GATE_IDLE_SECONDS", "600"))
READY_TIMEOUT = int(os.getenv("GATE_READY_TIMEOUT", "600"))
MAX_ACTIVE_PER_KEY = int(os.getenv("GATE_MAX_ACTIVE_PER_KEY", "4"))
JOB_TTL = int(os.getenv("GATE_JOB_TTL", "86400"))
ACE_DIR = os.path.expanduser(os.getenv("GATE_ACE_DIR", "~/ACE-Step-1.5"))
ACE_PYTHON = os.getenv("GATE_ACE_PYTHON", f"{ACE_DIR}/.venv/bin/python")
ACE_LOG = os.getenv("GATE_ACE_LOG", str(GATE_DIR / "acestep.log"))
GPU = os.getenv("GATE_GPU", "0")

log = logging.getLogger("acestep-gate")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

app = FastAPI(title="ACE-Step gate", docs_url=None, redoc_url=None, openapi_url=None)


# ── keys ────────────────────────────────────────────────────────────────────

def _load_keys():
    try:
        return json.loads(KEYS_FILE.read_text())
    except FileNotFoundError:
        return []


def authenticate(request: Request) -> str:
    header = request.headers.get("authorization", "")
    token = header[7:].strip() if header.lower().startswith("bearer ") else header.strip()
    if not token:
        raise HTTPException(401, "Missing Authorization: Bearer <key>")
    digest = hashlib.sha256(token.encode()).hexdigest()
    today = dt.date.today().isoformat()
    for entry in _load_keys():
        if hmac.compare_digest(entry["sha256"], digest):
            if entry.get("revoked"):
                raise HTTPException(401, "Key revoked")
            if entry.get("expires") and entry["expires"] < today:
                raise HTTPException(401, "Key expired")
            return entry["name"]
    raise HTTPException(401, "Invalid key")


# ── backend lifecycle ───────────────────────────────────────────────────────

class Backend:
    def __init__(self):
        self.proc: subprocess.Popen | None = None
        self.lock = asyncio.Lock()
        self.last_activity = time.time()
        self.started_at: float | None = None

    @property
    def owned(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    async def healthy(self) -> bool:
        try:
            async with httpx.AsyncClient(timeout=3) as c:
                r = await c.get(f"{BACKEND}/health")
                return r.status_code == 200
        except httpx.HTTPError:
            return False

    async def ensure(self) -> None:
        """Start ACE-Step if nothing is serving the backend port, then wait until healthy."""
        async with self.lock:
            if await self.healthy():
                return
            if not self.owned:
                env = dict(os.environ, CUDA_VISIBLE_DEVICES=GPU,
                           ACESTEP_INIT_LLM=os.getenv("GATE_ACE_INIT_LLM", "false"))
                env.pop("ACESTEP_API_KEY", None)  # bound to localhost; the gate is the auth
                logf = open(ACE_LOG, "ab")
                self.proc = subprocess.Popen(
                    [ACE_PYTHON, "-m", "acestep.api_server",
                     "--host", "127.0.0.1", "--port", str(ACE_PORT)],
                    cwd=ACE_DIR, env=env, stdout=logf, stderr=logf, start_new_session=True,
                )
                self.started_at = time.time()
                log.info("started ACE-Step pid=%s", self.proc.pid)
            deadline = time.time() + READY_TIMEOUT
            while time.time() < deadline:
                if self.proc is not None and self.proc.poll() is not None:
                    code = self.proc.returncode
                    self.proc = None
                    raise RuntimeError(f"ACE-Step exited during startup (code {code})")
                if await self.healthy():
                    log.info("ACE-Step ready after %.0fs", time.time() - (self.started_at or time.time()))
                    return
                await asyncio.sleep(2)
            raise RuntimeError("ACE-Step did not become ready in time")

    def stop(self) -> None:
        if not self.owned:
            return
        pid = self.proc.pid
        log.info("idle %ds: stopping ACE-Step pid=%s", IDLE_SECONDS, pid)
        os.killpg(pid, signal.SIGTERM)
        try:
            self.proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            os.killpg(pid, signal.SIGKILL)
            self.proc.wait(timeout=10)
        self.proc = None
        self.started_at = None


backend = Backend()


# ── jobs ────────────────────────────────────────────────────────────────────

# gate job id → {owner, status: warming|queued|running|completed|failed,
#                ace_task_id, files, metas, error, created}
JOBS: dict[str, dict] = {}


def _unfinished() -> list[dict]:
    return [j for j in JOBS.values() if j["status"] not in ("completed", "failed")]


def translate(params: dict) -> dict:
    prompt = str(params.get("tags") or params.get("prompt") or params.get("caption") or "")
    extras = [str(params[k]) for k in ("genre", "mood") if params.get(k)]
    if extras:
        prompt = ", ".join([prompt] + extras) if prompt else ", ".join(extras)
    lyrics = "" if params.get("instrumental") else str(params.get("lyrics") or "")
    duration = float(params.get("duration") or 60)
    body = {
        "prompt": prompt[:2000],
        "lyrics": lyrics[:6000],
        "audio_duration": max(10.0, min(duration, 480.0)),
        "inference_steps": max(1, min(int(params.get("num_inference_steps") or 8), 20)),
        "guidance_scale": float(params.get("guidance_scale") or 7.0),
        "batch_size": 1,
        "audio_format": "wav",
        "thinking": False,
    }
    if params.get("vocal_language"):
        body["vocal_language"] = str(params["vocal_language"])
    if params.get("time_signature"):
        body["time_signature"] = str(params["time_signature"])
    if params.get("tempo"):
        body["bpm"] = max(30, min(int(params["tempo"]), 300))
    if params.get("key"):
        body["key_scale"] = str(params["key"])
    if params.get("seed") is not None and int(params["seed"]) >= 0:
        body["seed"] = int(params["seed"])
        body["use_random_seed"] = False
    return body


def _unwrap(payload):
    """ACE-Step answers either bare or as {"data": ..., "code": ...}."""
    if isinstance(payload, dict) and "data" in payload and ("code" in payload or "error" in payload):
        return payload["data"]
    return payload


async def run_job(job_id: str, body: dict) -> None:
    job = JOBS[job_id]
    try:
        await backend.ensure()
        async with httpx.AsyncClient(timeout=60) as c:
            r = await c.post(f"{BACKEND}/release_task", json=body)
            r.raise_for_status()
            data = _unwrap(r.json())
        job["ace_task_id"] = data["task_id"]
        job["status"] = "queued"
        log.info("job %s (%s) → ace task %s", job_id, job["owner"], job["ace_task_id"])
        await follow(job)
    except Exception as exc:  # surfaced to the client through the poll
        log.exception("job %s failed", job_id)
        job["status"] = "failed"
        job["error"] = str(exc)[:500]


async def follow(job: dict) -> None:
    """Poll ACE-Step until the task is done. Runs whether or not the client polls."""
    async with httpx.AsyncClient(timeout=30) as c:
        while job["status"] in ("queued", "running"):
            await asyncio.sleep(2)
            r = await c.post(f"{BACKEND}/query_result", json={"task_id_list": [job["ace_task_id"]]})
            r.raise_for_status()
            items = _unwrap(r.json())
            item = items[0] if isinstance(items, list) and items else {}
            code = item.get("status")
            if code == 0:
                job["status"] = "running"
                continue
            results = item.get("result") or "[]"
            results = json.loads(results) if isinstance(results, str) else results
            if code == 1:
                job["files"] = [res.get("file") for res in results if res.get("file")]
                first = results[0] if results else {}
                job["metas"] = {
                    **(first.get("metas") or {}),
                    "seed": first.get("seed_value"),
                    "dit_model": first.get("dit_model"),
                }
                job["status"] = "completed" if job["files"] else "failed"
                if not job["files"]:
                    job["error"] = "ACE-Step reported success but returned no audio file"
            else:
                job["status"] = "failed"
                job["error"] = (results[0].get("error") if results and isinstance(results[0], dict) else None) \
                    or item.get("error") or "ACE-Step generation failed"
            backend.last_activity = time.time()


def _own_job(job_id: str, who: str) -> dict:
    job = JOBS.get(job_id)
    if not job or job["owner"] != who:
        raise HTTPException(404, "No such job")
    return job


# ── routes ──────────────────────────────────────────────────────────────────

@app.middleware("http")
async def touch(request: Request, call_next):
    response = await call_next(request)
    if response.status_code != 401:
        backend.last_activity = time.time()
    return response


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/api/v1/studio/health")
async def studio_health(request: Request):
    who = authenticate(request)
    state = "ready" if await backend.healthy() else "cold (starts on the first job)"
    return {"status": "ok", "key": who, "generator": state, "idle_unload_seconds": IDLE_SECONDS}


@app.post("/api/v1/studio/generate")
async def generate(request: Request):
    who = authenticate(request)
    if sum(1 for j in _unfinished() if j["owner"] == who) >= MAX_ACTIVE_PER_KEY:
        raise HTTPException(429, f"At most {MAX_ACTIVE_PER_KEY} unfinished jobs per key")
    payload = await request.json()
    params = payload.get("params", payload) if isinstance(payload, dict) else {}
    job_id = uuid.uuid4().hex
    JOBS[job_id] = {"owner": who, "status": "warming", "created": time.time(),
                    "ace_task_id": None, "files": [], "metas": {}, "error": None}
    asyncio.create_task(run_job(job_id, translate(params)))
    return {"id": job_id, "job_id": job_id, "status": "warming"}


@app.get("/api/v1/studio/jobs/{job_id}")
async def job_status(job_id: str, request: Request):
    job = _own_job(job_id, authenticate(request))
    out = {"id": job_id, "status": job["status"]}
    if job["status"] == "completed":
        out["result"] = {"variants": [{"index": i, "metadata": job["metas"]} for i, _ in enumerate(job["files"])]}
    if job["status"] == "failed":
        out["error"] = job["error"]
    return out


@app.get("/api/v1/studio/jobs/{job_id}/audio")
async def job_audio(job_id: str, request: Request, variant: int = 0):
    job = _own_job(job_id, authenticate(request))
    if job["status"] != "completed" or not (0 <= variant < len(job["files"])):
        raise HTTPException(409, "Audio not ready")
    file_ref = job["files"][variant]  # "/v1/audio?path=..." as issued by ACE-Step itself
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.get(f"{BACKEND}{file_ref}")
    if r.status_code != 200:
        raise HTTPException(502, f"Generator returned {r.status_code} for the audio")
    return Response(r.content, media_type=r.headers.get("content-type", "audio/wav"))


@app.post("/api/v1/studio/jobs/{job_id}/save")
async def job_save(job_id: str, request: Request):
    _own_job(job_id, authenticate(request))
    return {"saved": False, "note": "This server keeps no library; the track lives in your app."}


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def everything_else(path: str):
    return JSONResponse({"detail": "Not found"}, status_code=404)


# ── idle reaper ─────────────────────────────────────────────────────────────

async def reaper():
    while True:
        await asyncio.sleep(30)
        now = time.time()
        for jid in [k for k, j in JOBS.items() if now - j["created"] > JOB_TTL]:
            JOBS.pop(jid, None)
        if backend.owned and not _unfinished() and now - backend.last_activity > IDLE_SECONDS:
            async with backend.lock:
                await asyncio.to_thread(backend.stop)


@app.on_event("startup")
async def _startup():
    asyncio.create_task(reaper())


@app.on_event("shutdown")
async def _shutdown():
    backend.stop()
