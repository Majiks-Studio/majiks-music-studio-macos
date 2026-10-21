# Smoke test, run on the gate host: mint a throwaway key, render 30 s through the gate,
# check the WAV, revoke the key. The key value is never printed.
#   GATE_KEYS_FILE=/opt/acestep-gate/keys.json GATE_URL=http://127.0.0.1:8010 python smoke.py
import hashlib, json, secrets, time, wave, io, datetime as dt, httpx, os
K = os.getenv("GATE_KEYS_FILE", os.path.join(os.path.dirname(os.path.abspath(__file__)), "keys.json"))
tok = "mms_" + secrets.token_urlsafe(32)
h = hashlib.sha256(tok.encode()).hexdigest()
keys = json.load(open(K)); keys.append({"name": "smoke-test", "sha256": h, "expires": dt.date.today().isoformat(), "created": dt.date.today().isoformat()})
json.dump(keys, open(K, "w"), indent=1)
print("smoke key sha8", h[:8], flush=True)
H = {"Authorization": "Bearer " + tok}
B = os.getenv("GATE_URL", "http://127.0.0.1:8010")
try:
    c = httpx.Client(timeout=120)
    print("health", c.get(B + "/api/v1/studio/health", headers=H).json(), flush=True)
    t0 = time.time()
    r = c.post(B + "/api/v1/studio/generate", headers=H, json={"params": {"tags": "warm lo-fi hip hop, mellow keys, vinyl crackle", "lyrics": "", "instrumental": True, "duration": 30.0, "num_inference_steps": 8, "guidance_scale": 7.0, "seed": 42}})
    print("submit", r.status_code, "%.1fs" % (time.time() - t0), flush=True)
    jid = r.json()["id"]; last = None
    while True:
        time.sleep(2)
        s = c.get(B + f"/api/v1/studio/jobs/{jid}", headers=H).json()
        if s["status"] != last:
            print("%6.1fs status %s" % (time.time() - t0, s["status"]), flush=True); last = s["status"]
        if s["status"] in ("completed", "failed"): break
        if time.time() - t0 > 900: print("TIMEOUT"); break
    print("final", json.dumps(s)[:400], flush=True)
    if s["status"] == "completed":
        a = c.get(B + f"/api/v1/studio/jobs/{jid}/audio?variant=0", headers=H)
        w = wave.open(io.BytesIO(a.content))
        print("audio", a.status_code, len(a.content), "bytes", "%.1fs" % (w.getnframes() / w.getframerate()), w.getframerate(), "Hz", flush=True)
        print("save", c.post(B + f"/api/v1/studio/jobs/{jid}/save", headers=H).status_code, flush=True)
finally:
    keys = [k for k in json.load(open(K)) if k["sha256"] != h]
    json.dump(keys, open(K, "w"), indent=1)
    print("smoke key revoked", h[:8], "remaining keys", len(keys), flush=True)
