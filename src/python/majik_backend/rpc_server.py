from __future__ import annotations

import gc
import json
import logging
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Dict, Optional

from .tls import install_ca_env

# Before any urllib call. The bundled OpenSSL defaults to a Homebrew CA path
# that is not on a customer's Mac; install_ca_env points at the bundle's copy.
install_ca_env()

from .llm_providers import MLXProvider, ModelDownloadError, ProviderType
from .majik_agent import MajikAgentError, ask_majik, enhance_caption, generate_track_name, get_llm_router

ACE_GENERATOR_IMPORT_ERROR: Optional[str] = None

try:
    from .ace_generator import GenerationStepError, get_generator, RemoteACEStepGenerator
except Exception as ace_import_error:  # noqa: BLE001
    ACE_GENERATOR_IMPORT_ERROR = str(ace_import_error)
    class GenerationStepError(Exception):
        def __init__(
            self,
            code: str,
            message: str,
            fix: str,
            detail: Optional[str] = None,
            step: Optional[str] = None,
        ) -> None:
            super().__init__(message)
            self.code = code
            self.message = message
            self.fix = fix
            self.detail = detail
            self.step = step

    RemoteACEStepGenerator = None  # type: ignore[assignment,misc]

    def get_generator() -> Any:
        raise GenerationStepError(
            "ACE_STEP_NOT_FOUND",
            "ACE-Step dependencies are missing from the selected Python environment.",
            "Use the ACE-Step virtual environment Python and restart the app.",
            detail=ACE_GENERATOR_IMPORT_ERROR,
            step="ACE-Step init",
        )


def _get_generator_for_request(batch_size: int = 1) -> Any:
    """Return the appropriate generator based on GENERATION_MODE and available servers.

    Routing logic:
    - auto: batch (3+ tracks) → remote if available, single → local if available, fallback to whichever works
    - local_only: always local
    - remote_only: always remote
    - both: prefer remote for batch, local for single (caller handles parallel)
    """
    mode = os.getenv("GENERATION_MODE", "auto")
    server_url = os.getenv("ACE_STEP_SERVER_URL")
    api_key = os.getenv("ACE_STEP_SERVER_API_KEY")

    def _make_remote():
        if RemoteACEStepGenerator is None:
            from .ace_generator import RemoteACEStepGenerator as _Remote
            return _Remote(server_url, api_key)
        return RemoteACEStepGenerator(server_url, api_key)

    if mode == "remote_only":
        if not server_url:
            raise RPCError(-32010, "Remote-only mode but no ACE_STEP_SERVER_URL configured")
        return _make_remote()

    if mode == "local_only":
        return get_generator()

    # auto or both
    if server_url:
        if mode == "auto" and batch_size >= 3:
            return _make_remote()
        if mode == "auto":
            # Single track: prefer local if available, fallback to remote
            try:
                gen = get_generator()
                return gen
            except Exception:
                return _make_remote()
        # "both" mode — caller handles parallel; default to local for Python path
        return get_generator()

    # No server configured — must use local
    return get_generator()


logger = logging.getLogger("majik.rpc")

# ACE-Step HuggingFace repo ID for download
ACE_STEP_HF_REPO = "ACE-Step/Ace-Step1.5"
DEFAULT_ACE_STEP_PATH = str(Path.home() / "ACE-Step-1.5")
DEFAULT_APP_SUPPORT_PATH = str(Path.home() / "Library/Application Support/MajiksMusicStudio")
DEFAULT_LIBRARY_PATH = str(Path(DEFAULT_APP_SUPPORT_PATH) / "Audio")
DEFAULT_EXPORT_PATH = str(Path.home() / "Music")
LICENSE_FORMAT_RE = re.compile(r"^MS1-[A-Za-z0-9_-]{6,}-[A-Za-z0-9_-]{6,}$")

# Publishing server configuration (defaults to majiks.online)
DEFAULT_PUBLISH_SERVER = "https://majiks.online"

def _publish_server_url() -> str:
    """Return the configured publishing server base URL."""
    return os.getenv("PUBLISH_SERVER_URL", DEFAULT_PUBLISH_SERVER).rstrip("/")


def _bridge_headers(content_type: Optional[str] = None, access_token: Optional[str] = None) -> Dict[str, str]:
    """Return common headers for studio-bridge API requests.

    *access_token* must be a valid Keycloak access token. The server validates
    the JWT signature and extracts the user identity from the ``sub`` claim.
    """
    if not access_token:
        raise RPCError(-32602, "access_token is required — sign in to your majiks.online account in the Publisher tab")
    h: Dict[str, str] = {
        "Authorization": f"Bearer {access_token}",
        "User-Agent": "MajiksMusicStudio/3.2.2",
    }
    if content_type:
        h["Content-Type"] = content_type
    return h

ERROR_FIXES: Dict[str, str] = {
    "ACE_STEP_NOT_FOUND": "Install ACE-Step in Settings",
    "MODEL_NOT_FOUND": "Download model in Settings -> LLM",
    "OUT_OF_MEMORY": "Try shorter duration or smaller model",
    "PYTHON_CRASH": "Restart backend in Settings",
    "DISK_FULL": "Free up disk space",
    "DOWNLOAD_FAILED": "Check internet connection and retry",
    "CONVERSION_FAILED": "Check that the audio file exists and try again",
    "PUBLISH_FAILED": "Check your internet connection and try again",
    "AUTH_FAILED": "Re-authenticate in Publisher settings",
    "FINGERPRINT_FAILED": "Install Chromaprint (brew install chromaprint) and try again",
}


class RPCError(Exception):
    def __init__(self, code: int, message: str, data: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


class GenerationCancelled(Exception):
    """Raised when the user cancels an in-progress generation."""


# Threading event used to signal cancellation to in-progress generation.
# Set by cancel_generation RPC, checked inside progress callbacks.
_cancel_event = threading.Event()

# Lock to serialize stdout writes (main thread + reader thread both write responses).
_stdout_lock = threading.Lock()


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stderr)
    formatter = logging.Formatter("[%(levelname)s] %(message)s")
    handler.setFormatter(formatter)
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)

    # Also configure majik.agent logger so its logs are visible
    agent_logger = logging.getLogger("majik.agent")
    agent_logger.addHandler(handler)
    agent_logger.setLevel(logging.INFO)


def _json_error_response(request_id: Optional[str], error: RPCError) -> Dict[str, Any]:
    payload = {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {
            "code": error.code,
            "message": error.message,
        },
    }
    if error.data is not None:
        payload["error"]["data"] = error.data
    return payload


def _send_notification(method: str, params: Dict[str, Any]) -> None:
    payload = {"jsonrpc": "2.0", "method": method, "params": params}
    with _stdout_lock:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def _progress(request_id: Optional[str], stage: str, percent: int, message: str, **extra: Any) -> None:
    payload: Dict[str, Any] = {
        "id": request_id,
        "stage": stage,
        "percent": percent,
        "message": message,
    }
    payload.update(extra)
    _send_notification("progress", payload)


def _structured_error(
    code: str,
    message: str,
    fix: Optional[str] = None,
    *,
    detail: Optional[str] = None,
    step: Optional[str] = None,
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "code": code,
        "message": message,
        "fix": fix or ERROR_FIXES.get(code, ERROR_FIXES["PYTHON_CRASH"]),
    }
    if detail:
        payload["detail"] = detail
    if step:
        payload["step"] = step
    if extra:
        payload.update(extra)
    return payload


def _raise_user_error(
    code: str,
    message: str,
    *,
    fix: Optional[str] = None,
    step: Optional[str] = None,
    detail: Optional[str] = None,
    extra: Optional[Dict[str, Any]] = None,
) -> None:
    data = _structured_error(code, message, fix, detail=detail, step=step, extra=extra)
    raise RPCError(-32010, message, data)


def _normalize_license_key(key: str) -> str:
    return key.strip().replace(" ", "").replace("\n", "")


def is_license_format_valid(key: str) -> bool:
    return bool(LICENSE_FORMAT_RE.match(_normalize_license_key(key)))


def _verify_license_key(key: str) -> bool:
    # Optional backend recognition list. If empty, any formatted key is treated as unrecognized.
    known = [k.strip() for k in os.getenv("MAJIK_VALID_LICENSE_KEYS", "").split(",") if k.strip()]
    return _normalize_license_key(key) in known


def _disk_space_gb(path: Optional[str] = None) -> float:
    target = path or str(Path.home())
    return shutil.disk_usage(target).free / (1024 ** 3)


def _check_disk_space(required_gb: float, path: Optional[str] = None) -> Dict[str, Any]:
    free_gb = _disk_space_gb(path)
    ok = free_gb >= required_gb
    return {
        "ok": ok,
        "required_gb": float(required_gb),
        "free_gb": round(free_gb, 2),
        "message": (
            f"Need {required_gb:.0f}GB free, only {free_gb:.0f}GB available"
            if not ok
            else "Enough disk space available"
        ),
    }


def _get_total_ram_gb() -> float:
    try:
        page_size = os.sysconf("SC_PAGE_SIZE")
        phys_pages = os.sysconf("SC_PHYS_PAGES")
        return round((page_size * phys_pages) / (1024 ** 3), 2)
    except Exception:
        result = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.strip().isdigit():
            return round(int(result.stdout.strip()) / (1024 ** 3), 2)
    return 0.0


def _get_available_ram_gb() -> float:
    """Return available (free + inactive) RAM in GB via vm_stat."""
    try:
        result = subprocess.run(["vm_stat"], capture_output=True, text=True)
        if result.returncode != 0:
            return 0.0
        page_size = 16384  # Apple Silicon default
        for line in result.stdout.splitlines():
            if "page size of" in line:
                parts = line.split()
                for p in parts:
                    if p.isdigit():
                        page_size = int(p)
                        break
        free_pages = 0
        inactive_pages = 0
        for line in result.stdout.splitlines():
            if line.startswith("Pages free:"):
                free_pages = int(line.split(":")[1].strip().rstrip("."))
            elif line.startswith("Pages inactive:"):
                inactive_pages = int(line.split(":")[1].strip().rstrip("."))
        return round((free_pages + inactive_pages) * page_size / (1024 ** 3), 2)
    except Exception:
        return 0.0


def _get_system_info() -> Dict[str, Any]:
    machine = platform.machine().lower()
    cpu_arch = "Apple Silicon" if machine in {"arm64", "aarch64"} else "Intel"
    return {
        "total_ram_gb": _get_total_ram_gb(),
        "available_ram_gb": _get_available_ram_gb(),
        "available_disk_gb": round(_disk_space_gb(), 2),
        "macos_version": platform.mac_ver()[0] or platform.platform(),
        "cpu_architecture": cpu_arch,
    }


def _validate_ace_step_installation(path: str) -> Dict[str, Any]:
    root = Path(path).expanduser()
    if not root.exists():
        _raise_user_error(
            "ACE_STEP_NOT_FOUND",
            f"ACE-Step not found at {root}",
            fix="Install ACE-Step in Settings",
            step="ACE-Step init",
        )

    # Check for model weights (downloaded from HuggingFace)
    required_dirs = ["vae", "acestep-v15-turbo"]
    missing_dirs = [d for d in required_dirs if not (root / d).exists()]
    if missing_dirs:
        _raise_user_error(
            "ACE_STEP_NOT_FOUND",
            f"ACE-Step model weights missing: {', '.join(missing_dirs)}",
            fix="Reinstall ACE-Step in Settings",
            step="ACE-Step init",
        )

    # Check that the acestep Python package is installed (via pip)
    command = [
        sys.executable,
        "-c",
        "import acestep; from acestep.handler import AceStepHandler",
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        _raise_user_error(
            "ACE_STEP_NOT_FOUND",
            "ACE-Step Python package not installed.",
            fix="Reinstall ACE-Step in Settings and restart backend.",
            step="ACE-Step init",
            detail=result.stderr.strip() or result.stdout.strip() or "Import check failed",
        )

    return {
        "valid": True,
        "path": str(root),
        "message": "ACE-Step installation is valid",
    }


def _categorize_exception(exc: Exception) -> Dict[str, Any]:
    if isinstance(exc, GenerationCancelled):
        return _structured_error("CANCELLED", "Generation cancelled by user", step="generation")

    if isinstance(exc, RPCError):
        return exc.data or _structured_error("PYTHON_CRASH", exc.message)

    if isinstance(exc, GenerationStepError):
        return _structured_error(
            exc.code,
            exc.message,
            exc.fix,
            detail=exc.detail,
            step=exc.step,
        )

    if isinstance(exc, MajikAgentError):
        return _structured_error(exc.code, exc.message, exc.fix, detail=exc.detail)

    if isinstance(exc, ModelDownloadError):
        return _structured_error(exc.code, exc.message, exc.fix, detail=exc.detail)

    text = str(exc).lower()
    if "out of memory" in text:
        return _structured_error("OUT_OF_MEMORY", "Not enough memory.", step="generation", detail=str(exc))
    if "acestep" in text and ("not found" in text or "no module named" in text or "missing" in text):
        return _structured_error("ACE_STEP_NOT_FOUND", "ACE-Step is not installed.", step="ACE-Step init", detail=str(exc))
    if "model" in text and ("not found" in text or "missing" in text):
        return _structured_error("MODEL_NOT_FOUND", "Model not found.", step="model load", detail=str(exc))
    if "no space" in text or "enospc" in text or "disk" in text and "full" in text:
        return _structured_error("DISK_FULL", "Disk is full.", step="download", detail=str(exc))
    if "certificate_verify_failed" in text or "certificate verify failed" in text:
        return _structured_error(
            "DOWNLOAD_FAILED",
            "Could not verify the server's TLS certificate.",
            fix="Reinstall Majiks Music Studio. The app ships its own certificate bundle and does not need Homebrew.",
            step="download",
            detail=str(exc),
        )

    return _structured_error("PYTHON_CRASH", "Backend error.", detail=str(exc))


def _parse_params(params: Any) -> Dict[str, Any]:
    if params is None:
        return {}
    if not isinstance(params, dict):
        raise RPCError(-32602, "Params must be an object")
    return params


def _art_studio_generate(endpoint: str, body: dict) -> dict:
    """POST to Art Studio, poll for completion, return result."""
    import time as _time

    url = f"http://localhost:8420{endpoint}"
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            result = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:
        return {"error": f"Art Studio request failed: {exc}"}

    if not isinstance(result, dict):
        return {"error": "Art Studio returned an invalid generation response"}

    job_id = result.get("job_id")
    if not job_id:
        # Synchronous response — image returned directly
        return result

    # Poll for completion (5-minute timeout, 2-second intervals)
    status_url = f"http://localhost:8420/status/{job_id}"
    deadline = _time.monotonic() + 300
    while _time.monotonic() < deadline:
        _time.sleep(2)
        try:
            status_req = urllib.request.Request(status_url, method="GET")
            status_req.add_header("Accept", "application/json")
            with urllib.request.urlopen(status_req, timeout=10) as resp:
                status = json.loads(resp.read().decode("utf-8"))
        except Exception as exc:
            logger.warning("Art Studio poll failed: %s", exc)
            continue

        if not isinstance(status, dict):
            logger.warning("Art Studio returned an invalid status response")
            continue

        # Artwork's canonical StatusResponse field is `status`. Accept the
        # pre-1.5 `state` spelling temporarily so older installed servers can
        # still complete jobs during a rolling suite upgrade.
        raw_state = status.get("status")
        if raw_state in (None, ""):
            raw_state = status.get("state", "")
        state = raw_state.strip().lower() if isinstance(raw_state, str) else ""
        if state == "completed":
            image_path = status.get("image_path")
            if not isinstance(image_path, str) or not image_path:
                return {
                    "error": "Art Studio completed without an image path",
                    "job_id": job_id,
                }
            return {
                "job_id": job_id,
                "image_path": image_path,
                "prompt": status.get("prompt", body.get("prompt", "")),
            }
        elif state in ("failed", "error", "cancelled"):
            default_error = "Generation was cancelled" if state == "cancelled" else "Generation failed"
            return {
                "error": status.get("error") or status.get("message") or default_error,
                "job_id": job_id,
            }

    return {"error": "Art Studio generation timed out (5 minutes)", "job_id": job_id}


def handle_request(request: Dict[str, Any]) -> Dict[str, Any]:
    method = request.get("method")
    params = _parse_params(request.get("params"))

    if method == "cancel_generation":
        _cancel_event.set()
        logger.info("Generation cancellation requested")
        return {"result": {"status": "cancelled"}}

    if method == "ping":
        return {"result": {"status": "ok"}}

    if method == "get_system_info":
        return {"result": _get_system_info()}

    if method == "check_disk_space":
        required_gb = params.get("required_gb")
        if required_gb is None:
            raise RPCError(-32602, "Missing required param: required_gb")
        try:
            required = float(required_gb)
        except (TypeError, ValueError) as exc:
            raise RPCError(-32602, "required_gb must be a number") from exc
        if required <= 0:
            raise RPCError(-32602, "required_gb must be greater than 0")
        return {"result": _check_disk_space(required)}

    if method == "download_mlx_model":
        model_name = params.get("model")
        if not model_name:
            raise RPCError(-32602, "Missing required parameter: model")

        # Create a temporary provider just for downloading (don't save to router)
        provider = MLXProvider(model_name=model_name)

        def _mlx_progress(stage: str, percent: int, message: str) -> None:
            _progress(request.get("id"), stage, percent, message)

        # Download only - does NOT load into RAM
        provider.download_only(progress_callback=_mlx_progress)
        return {"result": {"status": "downloaded", "model": provider.model_name}}

    if method == "get_library_path":
        path = os.getenv("MAJIK_LIBRARY_PATH", DEFAULT_LIBRARY_PATH)
        return {"result": {"path": path}}

    if method == "get_export_path":
        path = os.getenv("MAJIK_EXPORT_PATH", DEFAULT_EXPORT_PATH)
        return {"result": {"path": path}}

    if method == "is_license_format_valid":
        key = params.get("key")
        if key is None:
            raise RPCError(-32602, "Missing required param: key")
        normalized = _normalize_license_key(str(key))
        valid = is_license_format_valid(normalized)
        return {
            "result": {
                "valid": valid,
                "normalized": normalized,
                "message": (
                    "License key format is valid"
                    if valid
                    else "License keys look like: MS1-xxxxxx-xxxxxx"
                ),
            }
        }

    if method == "validate_license_key":
        key = params.get("key")
        if key is None:
            raise RPCError(-32602, "Missing required param: key")
        normalized = _normalize_license_key(str(key))
        if not is_license_format_valid(normalized):
            return {
                "result": {
                    "valid": False,
                    "normalized": normalized,
                    "message": "License keys look like: MS1-xxxxxx-xxxxxx",
                }
            }
        if not _verify_license_key(normalized):
            return {
                "result": {
                    "valid": False,
                    "normalized": normalized,
                    "message": "License key not recognized. Check your purchase email.",
                }
            }
        return {"result": {"valid": True, "normalized": normalized, "message": "License key is valid"}}

    if method == "install_ace_step":
        install_path = os.path.expanduser(params.get("path") or DEFAULT_ACE_STEP_PATH)
        request_id = request.get("id")

        _progress(request_id, "install", 2, "Checking ACE-Step installation")
        if Path(install_path).exists():
            _progress(request_id, "install", 100, "ACE-Step already installed")
            return {
                "result": {
                    "status": "already_installed",
                    "path": install_path,
                    "validation": _validate_ace_step_installation(install_path),
                }
            }

        parent = str(Path(install_path).parent)
        os.makedirs(parent, exist_ok=True)

        _progress(request_id, "install", 20, "Downloading ACE-Step from HuggingFace")
        try:
            from huggingface_hub import snapshot_download

            # Download using huggingface_hub (no git/auth required for public repos)
            _progress(request_id, "install", 30, "Downloading ACE-Step model files (this may take several minutes)")
            snapshot_download(
                repo_id=ACE_STEP_HF_REPO,
                local_dir=install_path,
                local_dir_use_symlinks=False,
            )
        except Exception as e:
            detail = str(e)
            lowered = detail.lower()
            if "could not resolve host" in lowered or "failed to connect" in lowered or "timed out" in lowered or "connection" in lowered:
                _raise_user_error(
                    "DOWNLOAD_FAILED",
                    "Download failed: No internet connection",
                    fix="Connect to the internet and retry installation.",
                    step="ACE-Step download",
                    detail=detail,
                )
            if "no space left" in lowered or "disk" in lowered:
                _raise_user_error(
                    "DISK_FULL",
                    "Disk is full during ACE-Step installation.",
                    step="ACE-Step download",
                    detail=detail,
                )
            _raise_user_error(
                "PYTHON_CRASH",
                "ACE-Step download failed.",
                fix="Retry installation in Settings.",
                step="ACE-Step download",
                detail=detail,
            )

        # Check if PyTorch is already installed (pre-bundled in v1.1.5+)
        _progress(request_id, "install", 50, "Checking PyTorch installation...")
        try:
            import torch
            logger.info("PyTorch already installed: %s", torch.__version__)
            _progress(request_id, "install", 60, f"PyTorch {torch.__version__} found")
        except ImportError:
            # PyTorch not pre-installed, need to install it
            _progress(request_id, "install", 50, "Installing PyTorch (this may take a few minutes)...")
            try:
                pip_result = subprocess.run(
                    [sys.executable, "-m", "pip", "install", "torch", "torchaudio", "torchcodec", "einops", "loguru"],
                    capture_output=True,
                    text=True,
                    timeout=600,  # 10 minutes for torch
                )
                if pip_result.returncode != 0:
                    detail = (pip_result.stderr or pip_result.stdout).strip()
                    _raise_user_error(
                        "PYTHON_CRASH",
                        "Failed to install PyTorch.",
                        fix="Check your internet connection and try again.",
                        step="ACE-Step install",
                        detail=detail,
                    )
            except subprocess.TimeoutExpired:
                _raise_user_error(
                    "PYTHON_CRASH",
                    "PyTorch installation timed out.",
                    fix="Check your internet connection and try again.",
                    step="ACE-Step install",
                )

        # Check if acestep is already installed (pre-bundled in v1.1.5+)
        _progress(request_id, "install", 70, "Checking ACE-Step package...")
        try:
            import acestep
            logger.info("ACE-Step package already installed")
            _progress(request_id, "install", 80, "ACE-Step package found")
        except ImportError:
            # acestep not pre-installed, need to install it
            _progress(request_id, "install", 70, "Installing ACE-Step Python package...")
            try:
                pip_result = subprocess.run(
                    [sys.executable, "-m", "pip", "install", "--no-deps", "git+https://github.com/ace-step/ACE-Step.git"],
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
                if pip_result.returncode != 0:
                    detail = (pip_result.stderr or pip_result.stdout).strip()
                    # Non-fatal - the wrapper might still work
                    logger.warning("Could not install acestep package: %s", detail)
            except Exception as e:
                logger.warning("Failed to pip install acestep: %s", e)

        _progress(request_id, "install", 90, "Validating ACE-Step installation")
        validation = _validate_ace_step_installation(install_path)
        generator = get_generator()
        generator.project_root = install_path

        _progress(request_id, "install", 100, "ACE-Step installation complete")
        return {
            "result": {
                "status": "installed",
                "path": install_path,
                "validation": validation,
            }
        }

    if method == "validate_ace_step":
        # Priority: 1) explicit param, 2) ACE_STEP_ROOT env var, 3) default path
        target = os.path.expanduser(
            params.get("path")
            or os.getenv("ACE_STEP_ROOT")
            or DEFAULT_ACE_STEP_PATH
        )
        return {"result": _validate_ace_step_installation(target)}

    if method == "test_remote_ace_step":
        server_url = params.get("server_url") or os.getenv("ACE_STEP_SERVER_URL")
        if not server_url:
            return {"result": {"success": False, "message": "No server URL configured"}}
        try:
            base = server_url.rstrip("/")
            headers = {}
            api_key = params.get("api_key") or os.getenv("ACE_STEP_SERVER_API_KEY")
            if api_key:
                headers["Authorization"] = f"Bearer {api_key}"
            # Try /api/v1/studio/health first, fall back to /health
            for path in ["/api/v1/studio/health", "/health"]:
                try:
                    req = urllib.request.Request(f"{base}{path}", headers=headers, method="GET")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        body = resp.read().decode()
                        return {"result": {"success": resp.status == 200, "message": body}}
                except urllib.error.HTTPError:
                    continue
                except urllib.error.URLError:
                    continue
            # Neither endpoint responded
            return {"result": {"success": False, "message": f"No health endpoint found at {base}"}}
        except Exception as e:
            return {"result": {"success": False, "message": str(e)}}

    if method == "generate_music":
        caption = params.get("caption")
        if not caption:
            raise RPCError(-32602, "Missing required param: caption")
        output_dir = params.get("output_dir") or "./output"
        lyrics = params.get("lyrics")
        bpm = params.get("bpm")
        key = params.get("key")
        duration = params.get("duration", 150)
        count = params.get("count", 1)
        # Turbo model: 8 steps (default). Base model: 32-100 steps.
        num_inference_steps = params.get("num_inference_steps", 8)
        guidance_scale = params.get("guidance_scale", 4.5)
        lm_temperature = params.get("lm_temperature", 0.9)
        lm_cfg_scale = params.get("lm_cfg_scale", 2.5)
        seed = params.get("seed")
        model_name = params.get("model", "acestep-v15-turbo")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        genre = params.get("genre")
        mood = params.get("mood")
        artist = params.get("artist")
        album = params.get("album")
        time_signature = params.get("time_signature", "4")
        vocal_language = params.get("vocal_language", "")

        # ACE-Step v1.5 advanced diffusion parameters
        shift = float(params.get("shift", 3.0))
        infer_method = params.get("infer_method", "ode")
        use_adg = bool(params.get("use_adg", False))
        cfg_interval_start = float(params.get("cfg_interval_start", 0.0))
        cfg_interval_end = float(params.get("cfg_interval_end", 1.0))

        # ACE-Step v1.5 advanced LM parameters
        thinking = bool(params.get("thinking", True))
        lm_top_k = int(params.get("lm_top_k", 0))
        lm_top_p = float(params.get("lm_top_p", 0.9))
        lm_repetition_penalty = float(params.get("lm_repetition_penalty", 1.0))
        lm_negative_prompt = params.get("lm_negative_prompt", "NO USER INPUT")
        constrained_decoding = bool(params.get("constrained_decoding", True))

        try:
            duration = max(30, min(600, int(duration)))
        except (TypeError, ValueError) as exc:
            raise RPCError(-32602, "duration must be a number between 30 and 600") from exc
        try:
            count = max(1, min(5, int(count)))
        except (TypeError, ValueError) as exc:
            raise RPCError(-32602, "count must be a number between 1 and 5") from exc

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)

        generator = _get_generator_for_request()
        request_id = request.get("id")
        is_remote = isinstance(generator, RemoteACEStepGenerator) if RemoteACEStepGenerator else False

        memory_estimate = generator.estimate_memory_requirements(
            lm_model_path=lm_model,
            duration=duration,
            model_name=model_name,
        )
        system_ram_gb = _get_total_ram_gb()
        available_ram_gb = _get_available_ram_gb()
        minimum_gb = float(memory_estimate["minimum_gb"])
        recommended_gb = float(memory_estimate["recommended_gb"])
        peak_range = str(memory_estimate["expected_peak_gb"])

        # Skip memory checks for remote mode — memory is on the remote server
        if not is_remote:
            # Hard fail: total physical RAM is below the absolute minimum
            if system_ram_gb > 0 and system_ram_gb < minimum_gb:
                _raise_user_error(
                    "OUT_OF_MEMORY",
                    (
                        f"Likely insufficient RAM for {lm_model}: detected {system_ram_gb:.0f}GB, "
                        f"minimum ~{minimum_gb:.0f}GB (typical peak {peak_range}GB)."
                    ),
                    fix="Choose a smaller LM model (0.6B/1.7B), shorten duration, or close other apps.",
                    step="preflight",
                    extra={"memory_estimate": memory_estimate, "detected_ram_gb": system_ram_gb},
                )

            # Warn: available RAM right now is below minimum (other apps hogging memory)
            if available_ram_gb > 0 and available_ram_gb < minimum_gb:
                _progress(
                    request_id,
                    "preflight",
                    3,
                    (
                        f"Low available RAM: {available_ram_gb:.1f}GB free of {system_ram_gb:.0f}GB total. "
                        f"{lm_model} needs ~{minimum_gb:.0f}GB. "
                        f"Close other apps to avoid slowdowns from memory swapping."
                    ),
                )

            # Warn: total RAM below recommended
            if system_ram_gb > 0 and system_ram_gb < recommended_gb:
                _progress(
                    request_id,
                    "preflight",
                    5,
                    (
                        f"Memory warning: detected {system_ram_gb:.0f}GB RAM, "
                        f"{lm_model} is typically smoother at ~{recommended_gb:.0f}GB+ "
                        f"(peak can reach {peak_range}GB)."
                    ),
                )

            # Unload ALL LLM models (chat + engineer) + clear all caches before local ACE-Step
            from majik_backend.majik_agent import unload_all_llm
            unload_result = unload_all_llm()
            logger.info("All LLM models unloaded: %s (available RAM: %.1fGB)",
                         unload_result.get("message"), _get_available_ram_gb())

        _cancel_event.clear()

        def progress_callback(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        if count <= 1:
            output_path = os.path.join(output_dir, "variant-1.wav")
            metadata = generator.generate_music(
                caption=caption,
                output_path=output_path,
                lyrics=lyrics,
                bpm=bpm,
                key=key,
                duration=duration,
                num_inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                seed=seed,
                model_name=model_name,
                lm_model_path=lm_model,
                progress_callback=progress_callback,
                time_signature=time_signature,
                vocal_language=vocal_language,
                shift=shift,
                infer_method=infer_method,
                use_adg=use_adg,
                cfg_interval_start=cfg_interval_start,
                cfg_interval_end=cfg_interval_end,
                thinking=thinking,
                lm_top_k=lm_top_k,
                lm_top_p=lm_top_p,
                lm_repetition_penalty=lm_repetition_penalty,
                lm_negative_prompt=lm_negative_prompt,
                constrained_decoding=constrained_decoding,
            )
            metadata["memory_estimate"] = memory_estimate
            metadata["detected_ram_gb"] = system_ram_gb
            # Attach request metadata (not generation params)
            if genre:
                metadata["genre"] = genre
            if mood:
                metadata["mood"] = mood
            if artist:
                metadata["artist"] = artist
            if album:
                metadata["album"] = album

            # Post-generation cleanup (local mode only)
            if not is_remote:
                try:
                    generator.unload_models()
                    gc.collect()
                    import torch as _torch_cleanup
                    if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                        _torch_cleanup.mps.empty_cache()
                    logger.info("Post-generation cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
                except Exception:
                    pass

            # IMP-006: Reload chat LLM so user can chat immediately after generation
            try:
                from .majik_agent import reload_chat_llm
                reload_result = reload_chat_llm()
                logger.info("Chat LLM reload after generation: %s (available RAM: %.1fGB)",
                            reload_result.get("message", "done"), _get_available_ram_gb())
            except Exception as reload_err:
                logger.warning("Could not reload chat LLM after generation: %s", reload_err)

            return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

        variants = generator.generate_variants(
            caption=caption,
            output_dir=output_dir,
            count=count,
            lyrics=lyrics,
            bpm=bpm,
            key=key,
            duration=duration,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            lm_temperature=lm_temperature,
            lm_cfg_scale=lm_cfg_scale,
            seed=seed,
            model_name=model_name,
            lm_model_path=lm_model,
            progress_callback=progress_callback,
            time_signature=time_signature,
            vocal_language=vocal_language,
            shift=shift,
            infer_method=infer_method,
            use_adg=use_adg,
            cfg_interval_start=cfg_interval_start,
            cfg_interval_end=cfg_interval_end,
            thinking=thinking,
            lm_top_k=lm_top_k,
            lm_top_p=lm_top_p,
            lm_repetition_penalty=lm_repetition_penalty,
            lm_negative_prompt=lm_negative_prompt,
            constrained_decoding=constrained_decoding,
        )
        for variant in variants:
            variant["memory_estimate"] = memory_estimate
            variant["detected_ram_gb"] = system_ram_gb

        # Post-generation cleanup (local mode only)
        if not is_remote:
            try:
                generator.unload_models()
                gc.collect()
                import torch as _torch_cleanup
                if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                    _torch_cleanup.mps.empty_cache()
                logger.info("Post-generation cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
            except Exception:
                pass

        # IMP-006: Reload chat LLM so user can chat immediately after generation
        try:
            from .majik_agent import reload_chat_llm
            reload_result = reload_chat_llm()
            logger.info("Chat LLM reload after generation: %s (available RAM: %.1fGB)",
                        reload_result.get("message", "done"), _get_available_ram_gb())
        except Exception as reload_err:
            logger.warning("Could not reload chat LLM after generation: %s", reload_err)

        return {"result": {"variants": [{"audio_path": v.get("file_path"), "metadata": v} for v in variants]}}

    if method == "generate_cover":
        reference_audio = params.get("reference_audio")
        if not reference_audio or not os.path.exists(reference_audio):
            raise RPCError(-32602, "Missing or invalid reference_audio path")
        caption = params.get("caption", "")
        cover_strength = params.get("cover_strength", 0.5)
        try:
            cover_strength = max(0.0, min(1.0, float(cover_strength)))
        except (TypeError, ValueError):
            cover_strength = 0.5
        output_dir = params.get("output_dir") or "./output"
        lyrics = params.get("lyrics")
        bpm = params.get("bpm")
        key = params.get("key")
        duration = params.get("duration", 0)
        num_inference_steps = params.get("num_inference_steps", 8)
        guidance_scale = params.get("guidance_scale", 4.5)
        lm_temperature = params.get("lm_temperature", 0.9)
        lm_cfg_scale = params.get("lm_cfg_scale", 2.5)
        seed = params.get("seed")
        model_name = params.get("model", "acestep-v15-turbo")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        time_signature = params.get("time_signature", "4")
        vocal_language = params.get("vocal_language", "")

        # ACE-Step v1.5 advanced diffusion parameters
        shift = float(params.get("shift", 3.0))
        infer_method = params.get("infer_method", "ode")
        use_adg = bool(params.get("use_adg", False))
        cfg_interval_start = float(params.get("cfg_interval_start", 0.0))
        cfg_interval_end = float(params.get("cfg_interval_end", 1.0))

        # ACE-Step v1.5 advanced LM parameters
        thinking = bool(params.get("thinking", True))
        lm_top_k = int(params.get("lm_top_k", 0))
        lm_top_p = float(params.get("lm_top_p", 0.9))
        lm_negative_prompt = params.get("lm_negative_prompt", "NO USER INPUT")
        constrained_decoding = bool(params.get("constrained_decoding", True))

        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = 0

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "cover.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")
        is_remote = isinstance(generator, RemoteACEStepGenerator) if RemoteACEStepGenerator else False

        # Unload LLM models before local generation
        if not is_remote:
            from majik_backend.majik_agent import unload_all_llm
            unload_result = unload_all_llm()
            logger.info("All LLM models unloaded for cover: %s (available RAM: %.1fGB)",
                         unload_result.get("message"), _get_available_ram_gb())

        _cancel_event.clear()

        def progress_callback(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_cover(
            reference_audio=reference_audio,
            caption=caption,
            output_path=output_path,
            cover_strength=cover_strength,
            lyrics=lyrics,
            bpm=bpm,
            key=key,
            duration=duration,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            lm_temperature=lm_temperature,
            lm_cfg_scale=lm_cfg_scale,
            seed=seed,
            model_name=model_name,
            lm_model_path=lm_model,
            progress_callback=progress_callback,
            time_signature=time_signature,
            vocal_language=vocal_language,
            shift=shift,
            infer_method=infer_method,
            use_adg=use_adg,
            cfg_interval_start=cfg_interval_start,
            cfg_interval_end=cfg_interval_end,
            thinking=thinking,
            lm_top_k=lm_top_k,
            lm_top_p=lm_top_p,
            lm_negative_prompt=lm_negative_prompt,
            constrained_decoding=constrained_decoding,
        )

        # Post-generation cleanup (local mode only)
        if not is_remote:
            try:
                generator.unload_models()
                gc.collect()
                import torch as _torch_cleanup
                if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                    _torch_cleanup.mps.empty_cache()
                logger.info("Post-cover cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
            except Exception:
                pass

        # Reload chat LLM
        try:
            from .majik_agent import reload_chat_llm
            reload_result = reload_chat_llm()
            logger.info("Chat LLM reload after cover: %s", reload_result.get("message", "done"))
        except Exception as reload_err:
            logger.warning("Could not reload chat LLM after cover: %s", reload_err)

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    if method == "generate_continuation":
        source_audio = params.get("source_audio")
        if not source_audio or not os.path.exists(source_audio):
            raise RPCError(-32602, "Missing or invalid source_audio path")
        caption = params.get("caption", "")
        output_dir = params.get("output_dir") or "./output"
        lyrics = params.get("lyrics")
        bpm = params.get("bpm")
        key = params.get("key")
        duration = params.get("duration", 0)
        num_inference_steps = params.get("num_inference_steps", 8)
        guidance_scale = params.get("guidance_scale", 4.5)
        lm_temperature = params.get("lm_temperature", 0.9)
        lm_cfg_scale = params.get("lm_cfg_scale", 2.5)
        seed = params.get("seed")
        model_name = params.get("model", "acestep-v15-turbo")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        time_signature = params.get("time_signature", "4")
        vocal_language = params.get("vocal_language", "")

        # ACE-Step v1.5 advanced diffusion parameters
        shift = float(params.get("shift", 3.0))
        infer_method = params.get("infer_method", "ode")
        use_adg = bool(params.get("use_adg", False))
        cfg_interval_start = float(params.get("cfg_interval_start", 0.0))
        cfg_interval_end = float(params.get("cfg_interval_end", 1.0))

        # ACE-Step v1.5 advanced LM parameters
        thinking = bool(params.get("thinking", True))
        lm_top_k = int(params.get("lm_top_k", 0))
        lm_top_p = float(params.get("lm_top_p", 0.9))
        lm_negative_prompt = params.get("lm_negative_prompt", "NO USER INPUT")
        constrained_decoding = bool(params.get("constrained_decoding", True))

        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = 0

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "continuation.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")
        is_remote = isinstance(generator, RemoteACEStepGenerator) if RemoteACEStepGenerator else False

        # Unload LLM models before local generation
        if not is_remote:
            from majik_backend.majik_agent import unload_all_llm
            unload_result = unload_all_llm()
            logger.info("All LLM models unloaded for continuation: %s (available RAM: %.1fGB)",
                         unload_result.get("message"), _get_available_ram_gb())

        _cancel_event.clear()

        def progress_callback(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_continuation(
            source_audio=source_audio,
            caption=caption,
            output_path=output_path,
            lyrics=lyrics,
            bpm=bpm,
            key=key,
            duration=duration,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            lm_temperature=lm_temperature,
            lm_cfg_scale=lm_cfg_scale,
            seed=seed,
            model_name=model_name,
            lm_model_path=lm_model,
            progress_callback=progress_callback,
            time_signature=time_signature,
            vocal_language=vocal_language,
            shift=shift,
            infer_method=infer_method,
            use_adg=use_adg,
            cfg_interval_start=cfg_interval_start,
            cfg_interval_end=cfg_interval_end,
            thinking=thinking,
            lm_top_k=lm_top_k,
            lm_top_p=lm_top_p,
            lm_negative_prompt=lm_negative_prompt,
            constrained_decoding=constrained_decoding,
        )

        # Post-generation cleanup (local mode only)
        if not is_remote:
            try:
                generator.unload_models()
                gc.collect()
                import torch as _torch_cleanup
                if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                    _torch_cleanup.mps.empty_cache()
                logger.info("Post-continuation cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
            except Exception:
                pass

        # Reload chat LLM
        try:
            from .majik_agent import reload_chat_llm
            reload_result = reload_chat_llm()
            logger.info("Chat LLM reload after continuation: %s", reload_result.get("message", "done"))
        except Exception as reload_err:
            logger.warning("Could not reload chat LLM after continuation: %s", reload_err)

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    if method == "generate_repaint":
        source_audio = params.get("source_audio")
        if not source_audio or not os.path.exists(source_audio):
            raise RPCError(-32602, "Missing or invalid source_audio path")
        repainting_start = params.get("repainting_start", 0.0)
        repainting_end = params.get("repainting_end", -1.0)
        try:
            repainting_start = float(repainting_start)
        except (TypeError, ValueError):
            repainting_start = 0.0
        try:
            repainting_end = float(repainting_end)
        except (TypeError, ValueError):
            repainting_end = -1.0
        caption = params.get("caption", "")
        output_dir = params.get("output_dir") or "./output"
        lyrics = params.get("lyrics")
        bpm = params.get("bpm")
        key = params.get("key")
        duration = params.get("duration", 0)
        num_inference_steps = params.get("num_inference_steps", 50)
        guidance_scale = params.get("guidance_scale", 4.5)
        lm_temperature = params.get("lm_temperature", 0.9)
        lm_cfg_scale = params.get("lm_cfg_scale", 2.5)
        seed = params.get("seed")
        model_name = params.get("model", "acestep-v15-base")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        time_signature = params.get("time_signature", "4")
        vocal_language = params.get("vocal_language", "")

        # ACE-Step v1.5 advanced diffusion parameters
        shift = float(params.get("shift", 3.0))
        infer_method = params.get("infer_method", "ode")
        use_adg = bool(params.get("use_adg", False))
        cfg_interval_start = float(params.get("cfg_interval_start", 0.0))
        cfg_interval_end = float(params.get("cfg_interval_end", 1.0))

        # ACE-Step v1.5 advanced LM parameters
        thinking = bool(params.get("thinking", True))
        lm_top_k = int(params.get("lm_top_k", 0))
        lm_top_p = float(params.get("lm_top_p", 0.9))
        lm_negative_prompt = params.get("lm_negative_prompt", "NO USER INPUT")
        constrained_decoding = bool(params.get("constrained_decoding", True))

        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = 0

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "repaint.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")
        is_remote = isinstance(generator, RemoteACEStepGenerator) if RemoteACEStepGenerator else False

        # Unload LLM models before local generation
        if not is_remote:
            from majik_backend.majik_agent import unload_all_llm
            unload_result = unload_all_llm()
            logger.info("All LLM models unloaded for repaint: %s (available RAM: %.1fGB)",
                         unload_result.get("message"), _get_available_ram_gb())

        _cancel_event.clear()

        def progress_callback(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_repaint(
            source_audio=source_audio,
            repainting_start=repainting_start,
            repainting_end=repainting_end,
            caption=caption,
            output_path=output_path,
            lyrics=lyrics,
            bpm=bpm,
            key=key,
            duration=duration,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            lm_temperature=lm_temperature,
            lm_cfg_scale=lm_cfg_scale,
            seed=seed,
            model_name=model_name,
            lm_model_path=lm_model,
            progress_callback=progress_callback,
            time_signature=time_signature,
            vocal_language=vocal_language,
            shift=shift,
            infer_method=infer_method,
            use_adg=use_adg,
            cfg_interval_start=cfg_interval_start,
            cfg_interval_end=cfg_interval_end,
            thinking=thinking,
            lm_top_k=lm_top_k,
            lm_top_p=lm_top_p,
            lm_negative_prompt=lm_negative_prompt,
            constrained_decoding=constrained_decoding,
        )

        # Post-generation cleanup (local mode only)
        if not is_remote:
            try:
                generator.unload_models()
                gc.collect()
                import torch as _torch_cleanup
                if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                    _torch_cleanup.mps.empty_cache()
                logger.info("Post-repaint cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
            except Exception:
                pass

        # Reload chat LLM
        try:
            from .majik_agent import reload_chat_llm
            reload_result = reload_chat_llm()
            logger.info("Chat LLM reload after repaint: %s", reload_result.get("message", "done"))
        except Exception as reload_err:
            logger.warning("Could not reload chat LLM after repaint: %s", reload_err)

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    if method == "generate_extract":
        source_audio = params.get("source_audio")
        if not source_audio or not os.path.exists(source_audio):
            raise RPCError(-32602, "Missing or invalid source_audio path")
        instruction = params.get("instruction", "")
        if not instruction:
            raise RPCError(-32602, "Missing instruction (stems to extract)")
        caption = params.get("caption", "")
        output_dir = params.get("output_dir") or "./output"
        bpm = params.get("bpm")
        key = params.get("key")
        duration = params.get("duration", 0)
        num_inference_steps = params.get("num_inference_steps", 50)
        guidance_scale = params.get("guidance_scale", 4.5)
        lm_temperature = params.get("lm_temperature", 0.9)
        lm_cfg_scale = params.get("lm_cfg_scale", 2.5)
        seed = params.get("seed")
        model_name = params.get("model", "acestep-v15-base")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        time_signature = params.get("time_signature", "4")
        vocal_language = params.get("vocal_language", "")

        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = 0

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "extract.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")
        is_remote = isinstance(generator, RemoteACEStepGenerator) if RemoteACEStepGenerator else False

        if not is_remote:
            from majik_backend.majik_agent import unload_all_llm
            unload_result = unload_all_llm()
            logger.info("All LLM models unloaded for extract: %s (available RAM: %.1fGB)",
                         unload_result.get("message"), _get_available_ram_gb())

        _cancel_event.clear()

        def progress_callback(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_extract(
            source_audio=source_audio,
            instruction=instruction,
            caption=caption,
            output_path=output_path,
            bpm=bpm,
            key=key,
            duration=duration,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            lm_temperature=lm_temperature,
            lm_cfg_scale=lm_cfg_scale,
            seed=seed,
            model_name=model_name,
            lm_model_path=lm_model,
            progress_callback=progress_callback,
            time_signature=time_signature,
            vocal_language=vocal_language,
        )

        if not is_remote:
            try:
                generator.unload_models()
                gc.collect()
                import torch as _torch_cleanup
                if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                    _torch_cleanup.mps.empty_cache()
                logger.info("Post-extract cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
            except Exception:
                pass

        try:
            from .majik_agent import reload_chat_llm
            reload_result = reload_chat_llm()
            logger.info("Chat LLM reload after extract: %s", reload_result.get("message", "done"))
        except Exception as reload_err:
            logger.warning("Could not reload chat LLM after extract: %s", reload_err)

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    if method == "generate_lego":
        source_audio = params.get("source_audio", "")
        instruction = params.get("instruction", "")
        if not instruction:
            raise RPCError(-32602, "Missing instruction (what stem to generate)")
        caption = params.get("caption", "")
        output_dir = params.get("output_dir") or "./output"
        lyrics = params.get("lyrics")
        bpm = params.get("bpm")
        key = params.get("key")
        duration = params.get("duration", 0)
        num_inference_steps = params.get("num_inference_steps", 50)
        guidance_scale = params.get("guidance_scale", 4.5)
        lm_temperature = params.get("lm_temperature", 0.9)
        lm_cfg_scale = params.get("lm_cfg_scale", 2.5)
        seed = params.get("seed")
        model_name = params.get("model", "acestep-v15-base")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        time_signature = params.get("time_signature", "4")
        vocal_language = params.get("vocal_language", "")

        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = 0

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "lego.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")
        is_remote = isinstance(generator, RemoteACEStepGenerator) if RemoteACEStepGenerator else False

        if not is_remote:
            from majik_backend.majik_agent import unload_all_llm
            unload_result = unload_all_llm()
            logger.info("All LLM models unloaded for lego: %s (available RAM: %.1fGB)",
                         unload_result.get("message"), _get_available_ram_gb())

        _cancel_event.clear()

        def progress_callback(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_lego(
            source_audio=source_audio,
            instruction=instruction,
            caption=caption,
            output_path=output_path,
            lyrics=lyrics,
            bpm=bpm,
            key=key,
            duration=duration,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            lm_temperature=lm_temperature,
            lm_cfg_scale=lm_cfg_scale,
            seed=seed,
            model_name=model_name,
            lm_model_path=lm_model,
            progress_callback=progress_callback,
            time_signature=time_signature,
            vocal_language=vocal_language,
        )

        if not is_remote:
            try:
                generator.unload_models()
                gc.collect()
                import torch as _torch_cleanup
                if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                    _torch_cleanup.mps.empty_cache()
                logger.info("Post-lego cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
            except Exception:
                pass

        try:
            from .majik_agent import reload_chat_llm
            reload_result = reload_chat_llm()
            logger.info("Chat LLM reload after lego: %s", reload_result.get("message", "done"))
        except Exception as reload_err:
            logger.warning("Could not reload chat LLM after lego: %s", reload_err)

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    if method == "generate_auto_complete":
        source_audio = params.get("source_audio")
        if not source_audio or not os.path.exists(source_audio):
            raise RPCError(-32602, "Missing or invalid source_audio path")
        caption = params.get("caption", "")
        output_dir = params.get("output_dir") or "./output"
        lyrics = params.get("lyrics")
        bpm = params.get("bpm")
        key = params.get("key")
        duration = params.get("duration", 0)
        num_inference_steps = params.get("num_inference_steps", 50)
        guidance_scale = params.get("guidance_scale", 4.5)
        lm_temperature = params.get("lm_temperature", 0.9)
        lm_cfg_scale = params.get("lm_cfg_scale", 2.5)
        seed = params.get("seed")
        model_name = params.get("model", "acestep-v15-base")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        time_signature = params.get("time_signature", "4")
        vocal_language = params.get("vocal_language", "")

        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = 0

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "auto_complete.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")
        is_remote = isinstance(generator, RemoteACEStepGenerator) if RemoteACEStepGenerator else False

        if not is_remote:
            from majik_backend.majik_agent import unload_all_llm
            unload_result = unload_all_llm()
            logger.info("All LLM models unloaded for auto_complete: %s (available RAM: %.1fGB)",
                         unload_result.get("message"), _get_available_ram_gb())

        _cancel_event.clear()

        def progress_callback(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_auto_complete(
            source_audio=source_audio,
            caption=caption,
            output_path=output_path,
            lyrics=lyrics,
            bpm=bpm,
            key=key,
            duration=duration,
            num_inference_steps=num_inference_steps,
            guidance_scale=guidance_scale,
            lm_temperature=lm_temperature,
            lm_cfg_scale=lm_cfg_scale,
            seed=seed,
            model_name=model_name,
            lm_model_path=lm_model,
            progress_callback=progress_callback,
            time_signature=time_signature,
            vocal_language=vocal_language,
        )

        if not is_remote:
            try:
                generator.unload_models()
                gc.collect()
                import torch as _torch_cleanup
                if hasattr(_torch_cleanup, "mps") and hasattr(_torch_cleanup.mps, "empty_cache"):
                    _torch_cleanup.mps.empty_cache()
                logger.info("Post-auto_complete cleanup complete (available RAM: %.1fGB)", _get_available_ram_gb())
            except Exception:
                pass

        try:
            from .majik_agent import reload_chat_llm
            reload_result = reload_chat_llm()
            logger.info("Chat LLM reload after auto_complete: %s", reload_result.get("message", "done"))
        except Exception as reload_err:
            logger.warning("Could not reload chat LLM after auto_complete: %s", reload_err)

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    # ------------------------------------------------------------------
    # Gen Protocol v1 (lane L4, engine/contracts/gen-protocol.v1.yaml).
    # Thin delegation only: all logic lives in gen_protocol.py, which
    # ADAPTS the generate_* methods above (none of their behavior changes).
    # ------------------------------------------------------------------
    if method == "gen.submit":
        from . import gen_protocol as _gen_protocol

        op = params.get("op")
        gen_request = params.get("request")
        if not op or not isinstance(gen_request, dict):
            raise RPCError(-32602, "gen.submit requires params: {op: string, request: object}")

        def _gen_notify(job_id: str, stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            _progress(job_id, stage, percent, message, variant=variant)

        try:
            return {"result": _gen_protocol.submit(op, gen_request, notify=_gen_notify)}
        except _gen_protocol.GenProtocolError as exc:
            raise RPCError(-32010, exc.message, exc.to_dict()) from exc

    if method == "gen.status":
        from . import gen_protocol as _gen_protocol

        job_id = params.get("jobId")
        if not job_id:
            raise RPCError(-32602, "gen.status requires params: {jobId: string}")
        try:
            return {"result": _gen_protocol.status(job_id)}
        except _gen_protocol.GenProtocolError as exc:
            raise RPCError(-32010, exc.message, exc.to_dict()) from exc

    if method == "gen.cancel":
        from . import gen_protocol as _gen_protocol

        job_id = params.get("jobId")
        if not job_id:
            raise RPCError(-32602, "gen.cancel requires params: {jobId: string}")
        return {"result": _gen_protocol.cancel(job_id)}

    if method == "gen.capabilities":
        from . import gen_protocol as _gen_protocol

        return {"result": _gen_protocol.capabilities()}

    if method == "ask_majik":
        message = params.get("message")
        history = params.get("history")
        allow_auto_generation = params.get("allow_auto_generation", False)
        agent_config = params.get("agent_config")
        custom_system_prompt = params.get("custom_system_prompt")
        temperature_override = params.get("temperature_override")
        max_tokens_override = params.get("max_tokens_override")
        top_p_override = params.get("top_p_override")
        if not message:
            raise RPCError(-32602, "Missing required param: message")
        generator = get_generator() if allow_auto_generation else None

        # Create an on_partial callback that sends progressive display
        # notifications to the Swift frontend via JSON-RPC progress channel
        chat_request_id = request.get("id")
        def _chat_partial(text_so_far: str) -> None:
            _send_notification("progress", {
                "id": chat_request_id,
                "stage": "chat_partial",
                "percent": 0,
                "message": text_so_far,
            })

        result = ask_majik(
            message,
            history,
            generator=generator,
            allow_auto_generation=allow_auto_generation,
            agent_config=agent_config,
            custom_system_prompt=custom_system_prompt,
            temperature_override=temperature_override,
            max_tokens_override=max_tokens_override,
            top_p_override=top_p_override,
            on_partial=_chat_partial,
        )
        return {"result": result}

    if method == "enhance_caption":
        caption = params.get("caption")
        if not caption:
            raise RPCError(-32602, "Missing required param: caption")
        enhanced = enhance_caption(caption)
        return {"result": {"enhanced_caption": enhanced}}

    if method == "generate_track_name":
        track_metadata = {
            k: v for k, v in {
                "caption": params.get("caption"),
                "lyrics": params.get("lyrics"),
                "bpm": params.get("bpm"),
                "key": params.get("key"),
                "artist": params.get("artist"),
                "genre": params.get("genre"),
            }.items() if v is not None
        }
        result = generate_track_name(track_metadata)
        return {"result": result}

    if method == "extract_music_parameters":
        history = params.get("history")
        if not history:
            raise RPCError(-32602, "Missing required param: history")
        from .majik_agent import extract_music_parameters, MajikAgentError

        try:
            parameters = extract_music_parameters(history)
            return {"result": {"parameters": parameters}}
        except MajikAgentError as e:
            # Structured agent errors pass through with their details
            raise RPCError(-32010, e.message, _structured_error(e.code, e.message, e.fix, detail=e.detail)) from e
        except ValueError as e:
            # JSON parsing/extraction errors
            error_msg = str(e)
            if "empty response" in error_msg.lower():
                _raise_user_error(
                    "EXTRACTION_MODEL_ERROR",
                    "Extraction model returned empty response",
                    fix="Download the extraction model in Settings > LLM, or try restarting the backend.",
                    detail=error_msg,
                )
            else:
                _raise_user_error(
                    "EXTRACTION_FAILED",
                    "Could not extract parameters from conversation",
                    fix="Try rephrasing your music description or restart the backend.",
                    detail=error_msg,
                )
        except Exception as e:
            # Unexpected errors — provide targeted fix based on error pattern
            logger.exception("Extraction failed with unexpected error")
            error_text = str(e).lower()
            if "download" in error_text or "not downloaded" in error_text or "urlerror" in error_text:
                fix_msg = "Download the extraction model in Settings > LLM, or check your internet connection."
            elif "mlx" in error_text and ("not found" in error_text or "unavailable" in error_text or "import" in error_text):
                fix_msg = "MLX is not available on this system. Switch to a cloud provider or Ollama in Settings > LLM."
            elif "model" in error_text and ("not found" in error_text or "missing" in error_text):
                fix_msg = "Download the extraction model in Settings > LLM."
            elif "out of memory" in error_text or "oom" in error_text:
                fix_msg = "Not enough memory. Try a smaller extraction model in Settings > LLM, or restart the backend."
            elif "all llm providers failed" in error_text:
                fix_msg = "Check that a model is downloaded and configured in Settings > LLM, then restart the backend."
            else:
                fix_msg = "Restart the backend in Settings and try again."
            _raise_user_error(
                "EXTRACTION_FAILED",
                "Parameter extraction failed",
                fix=fix_msg,
                detail=str(e),
            )

    if method == "analyze_audio_file":
        file_path = params.get("file_path")
        existing_caption = params.get("caption") or ""
        existing_title = params.get("title") or ""
        if not file_path:
            raise RPCError(-32602, "Missing required param: file_path")
        if not os.path.exists(file_path):
            raise RPCError(-32602, f"Audio file not found: {file_path}")

        import librosa
        from .ace_generator import _extract_metadata

        # Step 1: Extract BPM, key, and duration from the audio signal
        try:
            bpm, key = _extract_metadata(file_path)
            duration = librosa.get_duration(path=file_path)
        except Exception as e:
            logger.exception("Audio analysis failed for: %s", file_path)
            _raise_user_error(
                "AUDIO_ANALYSIS_FAILED",
                f"Could not analyze audio file: {e}",
                fix="Ensure the file is a valid audio file (WAV, MP3, FLAC, etc.).",
                detail=str(e),
            )

        result: Dict[str, Any] = {}
        if bpm is not None:
            result["bpm"] = round(bpm)
        if key is not None:
            result["key"] = key
        if duration is not None:
            result["duration"] = round(duration, 1)

        # Step 2: If we have existing caption/title, run LLM extraction for genre/style
        description_text = existing_caption or existing_title
        if description_text:
            try:
                from .majik_agent import extract_music_parameters, MajikAgentError as _MAE
                # Build a synthetic conversation so the extraction pipeline can infer genre/style
                synthetic_history = [
                    {"role": "user", "content": f"I want music like this: {description_text}"},
                    {"role": "assistant", "content": (
                        f"Here's a track based on your description: {description_text}."
                        + (f" BPM: {round(bpm)}." if bpm else "")
                        + (f" Key: {key}." if key else "")
                        + (f" Duration: {round(duration)} seconds." if duration else "")
                    )},
                ]
                llm_params = extract_music_parameters(synthetic_history)
                # Merge LLM-extracted fields (caption, genre, lyrics) but prefer
                # audio-signal values for BPM/key/duration since those are measured.
                if "caption" in llm_params:
                    result["caption"] = llm_params["caption"]
                if "lyrics" in llm_params:
                    result["lyrics"] = llm_params["lyrics"]
                if "genre" in llm_params:
                    result["genre"] = llm_params["genre"]
                if "style" in llm_params:
                    result["style"] = llm_params["style"]
            except Exception as e:
                # LLM extraction is optional — audio-signal params are still useful
                logger.warning("LLM extraction failed during audio analysis (non-fatal): %s", e)

        return {"result": {"parameters": result}}

    if method == "import_audio":
        file_path = params.get("file_path")
        output_dir = params.get("output_dir") or "./output"
        if not file_path:
            raise RPCError(-32602, "Missing required param: file_path")
        generator = get_generator()
        metadata = generator.import_audio(file_path, output_dir)
        # Hoist the copied audio path so the Swift client can find it at the
        # top level (BackendViewModel.importAudio expects `audio_path`).
        # `metadata` is also returned for callers that want bpm/key/duration.
        return {
            "result": {
                "audio_path": metadata.get("file_path", ""),
                "metadata": metadata,
            }
        }

    if method == "understand_music":
        audio_path = params.get("audio_path")
        if not audio_path:
            raise RPCError(-32602, "Missing required param: audio_path")
        if not os.path.exists(audio_path):
            raise RPCError(-32602, f"Audio file not found: {audio_path}")

        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")

        def progress_cb(stage: str, percent: int, message: str) -> None:
            _progress(request.get("id"), stage, percent, message)

        progress_cb("analyzing", 10, "Extracting metadata from audio...")

        try:
            generator = _get_generator_for_request()
            result = generator.understand_music(audio_path, lm_model_path=lm_model)
        except GenerationStepError as exc:
            # AI extraction not available — fall back to basic librosa extraction
            logger.warning("understand_music: ACE-Step unavailable (%s), using librosa fallback", exc)
            import librosa as _lr
            from .ace_generator import _extract_metadata as _em
            _bpm, _key = _em(audio_path)
            try:
                _dur = _lr.get_duration(path=audio_path)
            except Exception:
                _dur = None
            result = {
                "caption": "",
                "lyrics": "",
                "bpm": _bpm,
                "key": _key,
                "duration": _dur,
                "language": "",
                "time_signature": "",
            }

        progress_cb("done", 100, "Metadata extraction complete")
        return {"result": result}

    if method == "export_track":
        file_path = params.get("file_path")
        output_path = params.get("output_path")
        format_name = params.get("format")
        bitrate = params.get("bitrate")
        track_metadata = params.get("metadata")  # Optional: write JSON sidecar

        if not all([file_path, output_path, format_name]):
            raise RPCError(-32602, "Missing required params: file_path, output_path, format")

        def progress_cb(stage: str, percent: int, message: str) -> None:
            _progress(request.get("id"), stage, percent, message)

        try:
            generator = get_generator()
            result = generator.export_track(
                file_path, output_path, format_name, bitrate=bitrate, progress_callback=progress_cb
            )

            # Write JSON sidecar alongside exported audio
            if track_metadata and output_path:
                import json as _json
                sidecar_path = os.path.splitext(output_path)[0] + ".json"
                try:
                    with open(sidecar_path, "w", encoding="utf-8") as sf:
                        _json.dump(track_metadata, sf, indent=2, default=str)
                    result["sidecar_path"] = sidecar_path
                    logger.info("Wrote metadata sidecar: %s", sidecar_path)
                except Exception as sidecar_err:
                    logger.warning("Failed to write sidecar: %s", sidecar_err)

            return {"result": result}
        except FileNotFoundError as e:
            raise RPCError(-32010, f"Source audio file not found: {file_path}", {"code": "FILE_NOT_FOUND", "detail": str(e)}) from e
        except RuntimeError as e:
            error_msg = str(e)
            if "ffmpeg" in error_msg.lower():
                raise RPCError(-32010, "FFmpeg is required for this format", {"code": "FFMPEG_MISSING", "detail": error_msg, "fix": "Install FFmpeg via: brew install ffmpeg"}) from e
            raise RPCError(-32010, f"Export failed: {error_msg}", {"code": "EXPORT_ERROR", "detail": error_msg}) from e
        except Exception as e:
            logger.exception("Export failed with unexpected error")
            raise RPCError(-32010, f"Export failed: {e}", {"code": "EXPORT_ERROR", "detail": str(e)}) from e

    if method == "export_stems":
        file_path = params.get("file_path")
        output_dir = params.get("output_dir")
        if not file_path or not output_dir:
            raise RPCError(-32602, "Missing required params: file_path, output_dir")
        generator = get_generator()
        try:
            result = generator.export_stems(file_path, output_dir)
            return {"result": result}
        except Exception as exc:  # noqa: BLE001
            structured = _categorize_exception(exc)
            raise RPCError(-32001, f"Stem export failed: {structured['message']}", structured) from exc

    # ── Song Package Import (Pipeline Step 3) ─────────────────────
    if method == "import_song_package":
        tags = params.get("tags") or params.get("caption")
        if not tags:
            raise RPCError(-32602, "Missing required param: tags (or caption)")
        lyrics = params.get("lyrics", "")
        bpm = params.get("bpm") or params.get("tempo")
        key_param = params.get("key")
        duration = params.get("duration") or params.get("duration_target", 150)
        genre = params.get("genre")
        mood = params.get("mood")
        artist = params.get("artist")
        album = params.get("album")
        content_type = params.get("content_type")
        inspired_by = params.get("inspired_by")
        source_urls = params.get("source_urls", [])
        topic = params.get("topic")
        topic_tags = params.get("topic_tags", [])
        seed = params.get("seed")
        output_dir = params.get("output_dir") or "./output"

        try:
            duration = max(30, min(600, int(duration)))
        except (TypeError, ValueError) as exc:
            raise RPCError(-32602, "duration must be a number between 30 and 600") from exc

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "variant-1.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")

        _cancel_event.clear()

        def progress_cb(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_music(
            caption=tags,
            output_path=output_path,
            lyrics=lyrics if lyrics else None,
            bpm=int(bpm) if bpm else None,
            key=key_param,
            duration=duration,
            progress_callback=progress_cb,
            seed=seed,
            genre=genre,
            mood=mood,
            artist=artist,
            album=album,
        )

        # Attach pipeline metadata to result
        metadata["content_type"] = content_type
        metadata["inspired_by"] = inspired_by
        metadata["source_urls"] = source_urls
        metadata["topic"] = topic
        metadata["topic_tags"] = topic_tags

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    # ── Genre Variation Generation ─────────────────────────────────
    if method == "generate_variation":
        source_tags = params.get("tags") or params.get("caption")
        if not source_tags:
            raise RPCError(-32602, "Missing required param: tags (original track style)")
        lyrics = params.get("lyrics", "")
        target_genre = params.get("target_genre")
        if not target_genre:
            raise RPCError(-32602, "Missing required param: target_genre")
        bpm_override = params.get("bpm")
        key_param = params.get("key")
        duration = params.get("duration", 150)
        seed = params.get("seed")
        source_track_id = params.get("source_track_id")
        output_dir = params.get("output_dir") or "./output"

        try:
            duration = max(30, min(600, int(duration)))
        except (TypeError, ValueError) as exc:
            raise RPCError(-32602, "duration must be a number") from exc

        # Build new tags for the target genre using genre templates
        from .model_configs import GENRE_TEMPLATES
        template = GENRE_TEMPLATES.get(target_genre.lower(), {})
        genre_tags = template.get("tags", target_genre)
        genre_bpm_range = template.get("bpm_range", (80, 140))

        # Use BPM override, else genre sweet spot midpoint
        if bpm_override:
            final_bpm = int(bpm_override)
        else:
            final_bpm = (genre_bpm_range[0] + genre_bpm_range[1]) // 2

        # Combine original style concepts with target genre tags
        variation_caption = f"{genre_tags}, {source_tags}"

        track_id = str(uuid.uuid4())
        output_dir = os.path.join(output_dir, track_id)
        os.makedirs(output_dir, exist_ok=True)
        output_path = os.path.join(output_dir, "variant-1.wav")

        generator = _get_generator_for_request()
        request_id = request.get("id")

        _cancel_event.clear()

        def progress_cb_var(stage: str, percent: int, message: str, variant: Optional[int] = None) -> None:
            if _cancel_event.is_set():
                raise GenerationCancelled("Generation cancelled by user")
            _progress(request_id, stage, percent, message, variant=variant)

        metadata = generator.generate_music(
            caption=variation_caption,
            output_path=output_path,
            lyrics=lyrics if lyrics else None,
            bpm=final_bpm,
            key=key_param,
            duration=duration,
            progress_callback=progress_cb_var,
            seed=seed,
            genre=target_genre,
        )

        metadata["source_track_id"] = source_track_id
        metadata["target_genre"] = target_genre
        metadata["variation_of"] = source_tags

        return {"result": {"audio_path": metadata.get("file_path", output_path), "metadata": metadata}}

    # ── Batch Import & Generation ─────────────────────────────────
    if method == "batch_import_packages":
        album_name = params.get("album", "")
        artist_name = params.get("artist", "")
        tracks = params.get("tracks", [])
        if not tracks:
            raise RPCError(-32602, "Missing required param: tracks (array of song packages)")
        output_dir = params.get("output_dir") or "./output"

        results = []
        for idx, track_params in enumerate(tracks):
            # Merge album/artist defaults if not specified per-track
            if not track_params.get("artist") and artist_name:
                track_params["artist"] = artist_name
            if not track_params.get("album") and album_name:
                track_params["album"] = album_name
            track_params["output_dir"] = output_dir

            try:
                sub_request = {"jsonrpc": "2.0", "id": f"batch-{idx}", "method": "import_song_package", "params": track_params}
                sub_result = handle_request(sub_request)
                if "error" in sub_result:
                    results.append({"index": idx, "error": sub_result["error"]["message"]})
                else:
                    results.append({"index": idx, "result": sub_result.get("result")})
            except Exception as exc:
                results.append({"index": idx, "error": str(exc)})

        return {"result": {"tracks": results, "total": len(tracks), "succeeded": sum(1 for r in results if "result" in r)}}

    if method == "list_models":
        generator = get_generator()
        models = generator.list_models()
        return {"result": {"models": models}}

    if method == "list_llm_providers":
        router = get_llm_router()
        available = router.list_available_providers()
        current_provider = router.config.provider.value
        fallback_provider = router.config.fallback_provider.value if router.config.fallback_provider else None
        return {
            "result": {
                "available": available,
                "current": current_provider,
                "fallback": fallback_provider,
                "models": {
                    "mlx_local": router.config.mlx_model,
                    "openrouter": router.config.openrouter_model,
                    "anthropic": router.config.anthropic_model,
                    "openai": router.config.openai_model,
                    "deepseek": router.config.deepseek_model,
                    "gemini": router.config.gemini_model,
                },
            }
        }

    if method == "set_llm_provider":
        provider_name = params.get("provider")
        if not provider_name:
            raise RPCError(-32602, "Missing required param: provider")

        try:
            provider_type = ProviderType(provider_name)
        except ValueError as exc:
            raise RPCError(-32602, f"Invalid provider: {provider_name}") from exc

        router = get_llm_router()
        router.config.provider = provider_type

        fallback_name = params.get("fallback_provider")
        if fallback_name:
            try:
                router.config.fallback_provider = ProviderType(fallback_name)
            except ValueError as exc:
                raise RPCError(-32602, f"Invalid fallback provider: {fallback_name}") from exc

        return {
            "result": {
                "provider": provider_type.value,
                "fallback": router.config.fallback_provider.value if router.config.fallback_provider else None,
            }
        }

    if method == "unload_llm":
        generator = get_generator()
        result = generator.unload_llm()
        return {"result": result}

    if method == "unload_models":
        generator = get_generator()
        result = generator.unload_models()
        return {"result": result}

    if method == "reload_chat_llm":
        try:
            from .majik_agent import reload_chat_llm
            result = reload_chat_llm()
            return {"result": result}
        except Exception as e:
            logger.warning("reload_chat_llm failed: %s", e)
            return {"result": {"status": "error", "message": str(e)}}

    if method == "reload_llm":
        model_name = params.get("model", "acestep-v15-turbo")
        lm_model = params.get("lm_model", "acestep-5Hz-lm-1.7B")
        generator = get_generator()
        result = generator.reload_llm(model_name=model_name, lm_model_path=lm_model)
        return {"result": result}

    if method == "list_available_models":
        generator = get_generator()
        models = generator.list_available_models()
        return {"result": models}

    if method == "download_model":
        model_id = params.get("model_id")
        if not model_id:
            raise RPCError(-32602, "Missing required parameter: model_id")

        generator = get_generator()
        request_id = request.get("id")

        # Progress callback to send updates to frontend
        def progress_callback(progress_data):
            _progress(
                request_id,
                progress_data.get("status", "downloading"),
                progress_data.get("progress", 0),
                progress_data.get("message", "Downloading..."),
                file=progress_data.get("file")
            )

        result = generator.download_model(model_id, progress_callback=progress_callback)
        return {"result": result}

    # ── Artist Profiles ─────────────────────────────────────────────

    if method == "list_artist_profiles":
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        if not access_token:
            raise RPCError(-32602, "Not authenticated — sign in via the Publisher tab")

        query_params: Dict[str, Any] = {
            "offset": params.get("offset", 0),
            "limit": params.get("limit", 100),
        }
        # Server extracts user identity from JWT — no need to send keycloak_id
        query = urllib.parse.urlencode(query_params)
        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles?{query}"

        req = urllib.request.Request(
            url,
            headers=_bridge_headers(access_token=access_token),
            method="GET",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="artist_profiles")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="artist_profiles")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="artist_profiles")

    if method == "create_artist_profile":
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        artist_name = params.get("artist_name")
        if not access_token or not artist_name:
            raise RPCError(-32602, "Missing required parameters: access_token, artist_name")

        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles"

        body_dict: Dict[str, Any] = {"artist_name": artist_name}
        # Server extracts user identity from JWT — no need to send keycloak_id
        body = json.dumps(body_dict).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers=_bridge_headers("application/json", access_token=access_token),
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="create_profile")
            if e.code == 409:
                _raise_user_error("SERVER_ERROR", f"Profile limit reached or duplicate name: {resp_body}", fix="Delete an existing profile first or use a different name", step="create_profile")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="create_profile")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="create_profile")

    if method == "update_artist_profile":
        profile_id = params.get("profile_id")
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        if not profile_id or not access_token:
            raise RPCError(-32602, "Missing required parameters: profile_id, access_token")

        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles/{profile_id}"

        body_dict: Dict[str, Any] = {}
        # Server extracts user identity from JWT — no need to send keycloak_id
        for field in ("artist_name", "website", "social_links"):
            val = params.get(field)
            if val is not None:
                body_dict[field] = val

        body = json.dumps(body_dict).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers=_bridge_headers("application/json", access_token=access_token),
            method="PUT",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="update_profile")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="update_profile")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="update_profile")

    if method == "delete_artist_profile":
        profile_id = params.get("profile_id")
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        if not profile_id or not access_token:
            raise RPCError(-32602, "Missing required parameters: profile_id, access_token")

        query_params: Dict[str, Any] = {}
        # Server extracts user identity from JWT — no need to send keycloak_id
        query = urllib.parse.urlencode(query_params) if query_params else ""
        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles/{profile_id}"
        if query:
            url += f"?{query}"

        req = urllib.request.Request(
            url,
            headers=_bridge_headers(access_token=access_token),
            method="DELETE",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="delete_profile")
            if e.code == 409:
                _raise_user_error("SERVER_ERROR", f"Cannot delete: {resp_body}", fix="Reassign tracks using this profile before deleting it", step="delete_profile")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="delete_profile")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="delete_profile")

    # ── Publishing ──────────────────────────────────────────────────

    if method == "convert_audio_for_publish":
        source_path = params.get("source_path")
        if not source_path:
            raise RPCError(-32602, "Missing required parameter: source_path")

        if not os.path.exists(source_path):
            _raise_user_error(
                "CONVERSION_FAILED",
                f"Audio file not found: {source_path}",
                fix="Check that the audio file exists and try again",
                step="convert",
            )

        request_id = request.get("id")
        _progress(request_id, "convert", 5, "Converting to FLAC + M4A 256k + M4A 128k...")

        flac_fd, flac_path = tempfile.mkstemp(suffix=".flac")
        os.close(flac_fd)
        m4a_fd, m4a_path = tempfile.mkstemp(suffix="_256.m4a")
        os.close(m4a_fd)
        m4a_low_fd, m4a_low_path = tempfile.mkstemp(suffix="_128.m4a")
        os.close(m4a_low_fd)

        try:
            # FLAC (lossless master)
            _progress(request_id, "convert", 15, "Encoding FLAC lossless...")
            subprocess.run(
                ["afconvert", source_path, flac_path, "-d", "flac", "-f", "flac"],
                check=True,
                capture_output=True,
            )
            # M4A 256kbps (standard streaming)
            _progress(request_id, "convert", 45, "Encoding M4A 256kbps...")
            subprocess.run(
                [
                    "afconvert", source_path, m4a_path,
                    "-d", "aac",
                    "-f", "m4af",
                    "-b", "256000",
                    "-q", "127",
                ],
                check=True,
                capture_output=True,
            )
            # M4A 128kbps (mobile / free tier)
            _progress(request_id, "convert", 75, "Encoding M4A 128kbps...")
            subprocess.run(
                [
                    "afconvert", source_path, m4a_low_path,
                    "-d", "aac",
                    "-f", "m4af",
                    "-b", "128000",
                    "-q", "127",
                ],
                check=True,
                capture_output=True,
            )
        except subprocess.CalledProcessError as e:
            for p in (flac_path, m4a_path, m4a_low_path):
                if os.path.exists(p):
                    os.unlink(p)
            _raise_user_error(
                "CONVERSION_FAILED",
                f"afconvert failed: {e.stderr.decode()[:200]}",
                step="convert",
            )

        source_size_mb = round(os.path.getsize(source_path) / (1024 * 1024), 2)
        flac_size_mb = round(os.path.getsize(flac_path) / (1024 * 1024), 2)
        m4a_size_mb = round(os.path.getsize(m4a_path) / (1024 * 1024), 2)
        m4a_low_size_mb = round(os.path.getsize(m4a_low_path) / (1024 * 1024), 2)

        _progress(request_id, "convert", 100,
                  f"Converted: {source_size_mb}MB → FLAC {flac_size_mb}MB + M4A 256k {m4a_size_mb}MB + M4A 128k {m4a_low_size_mb}MB")

        return {
            "result": {
                "flac_path": flac_path,
                "m4a_path": m4a_path,
                "m4a_low_path": m4a_low_path,
                "source_size_mb": source_size_mb,
                "flac_size_mb": flac_size_mb,
                "m4a_size_mb": m4a_size_mb,
                "m4a_low_size_mb": m4a_low_size_mb,
            }
        }

    if method == "publish_track":
        # Support both legacy m4a_path and new audio_path (FLAC) param
        audio_path = params.get("audio_path") or params.get("m4a_path")
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        title = params.get("title")
        studio_track_id = params.get("studio_track_id")

        if not all([audio_path, title, studio_track_id]) or not access_token:
            raise RPCError(-32602, "Missing required parameters: audio_path/m4a_path, access_token, title, studio_track_id")

        if not os.path.exists(audio_path):
            _raise_user_error(
                "PUBLISH_FAILED",
                f"Audio file not found: {audio_path}",
                step="upload",
            )

        request_id = request.get("id")
        _progress(request_id, "upload", 10, "Preparing upload...")

        # Build multipart/form-data body using stdlib
        boundary = f"----MajikStudioBridge{uuid.uuid4().hex}"
        body_parts: list[bytes] = []

        # Text fields
        # (server extracts the user identity from the Keycloak token)
        form_fields: Dict[str, str] = {
            "title": title[:500],
            "studio_track_id": studio_track_id,
        }
        # Server extracts user identity from JWT — no need to send keycloak_id
        for opt_key, param_key in [
            ("artist", "artist"),
            ("genre", "genre"),
            ("album", "album"),
            ("bpm", "bpm"),
            ("musical_key", "musical_key"),
            ("lyrics", "lyrics"),
            ("duration", "duration"),
            ("fingerprint", "fingerprint"),
            ("generation_params", "generation_params"),
            ("artist_profile_id", "artist_profile_id"),
            ("parent_track_id", "parent_track_id"),
            ("lyrics_lrc", "lyrics_lrc"),
            ("description", "description"),
            ("backstory", "backstory"),
            ("backstory_visibility", "backstory_visibility"),
            ("subgenre", "subgenre"),
            ("mood", "mood"),
            ("energy", "energy"),
            ("language", "language"),
            ("explicit", "explicit"),
            ("tags", "tags"),
            ("credits", "credits"),
            ("scheduled_at", "scheduled_at"),
            ("isrc", "isrc"),
            ("request_isrc", "request_isrc"),
        ]:
            val = params.get(param_key)
            if val is not None:
                form_fields[opt_key] = str(val)

        for field_name, field_value in form_fields.items():
            body_parts.append(f"--{boundary}\r\n".encode())
            body_parts.append(
                f'Content-Disposition: form-data; name="{field_name}"\r\n\r\n'.encode()
            )
            body_parts.append(f"{field_value}\r\n".encode())

        # Audio file field (FLAC lossless master or legacy M4A)
        audio_filename = os.path.basename(audio_path)
        audio_ext = os.path.splitext(audio_filename)[1].lower()
        audio_content_type = "audio/flac" if audio_ext == ".flac" else "audio/mp4"
        body_parts.append(f"--{boundary}\r\n".encode())
        body_parts.append(
            f'Content-Disposition: form-data; name="audio_file"; filename="{audio_filename}"\r\n'.encode()
        )
        body_parts.append(f"Content-Type: {audio_content_type}\r\n\r\n".encode())
        with open(audio_path, "rb") as f:
            body_parts.append(f.read())
        body_parts.append(b"\r\n")

        # Artwork file field (optional)
        artwork_path = params.get("artwork_path")
        if artwork_path and os.path.exists(artwork_path):
            artwork_filename = os.path.basename(artwork_path)
            # Detect content type from extension
            ext = os.path.splitext(artwork_filename)[1].lower()
            content_type = {
                ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".png": "image/png", ".webp": "image/webp",
            }.get(ext, "image/jpeg")
            body_parts.append(f"--{boundary}\r\n".encode())
            body_parts.append(
                f'Content-Disposition: form-data; name="artwork"; filename="{artwork_filename}"\r\n'.encode()
            )
            body_parts.append(f"Content-Type: {content_type}\r\n\r\n".encode())
            with open(artwork_path, "rb") as f:
                body_parts.append(f.read())
            body_parts.append(b"\r\n")

        # Album artwork file field (optional, separate from track artwork)
        album_artwork_path = params.get("album_artwork_path")
        if album_artwork_path and os.path.exists(album_artwork_path):
            album_art_filename = os.path.basename(album_artwork_path)
            ext = os.path.splitext(album_art_filename)[1].lower()
            content_type = {
                ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".png": "image/png", ".webp": "image/webp",
            }.get(ext, "image/jpeg")
            body_parts.append(f"--{boundary}\r\n".encode())
            body_parts.append(
                f'Content-Disposition: form-data; name="album_artwork"; filename="{album_art_filename}"\r\n'.encode()
            )
            body_parts.append(f"Content-Type: {content_type}\r\n\r\n".encode())
            with open(album_artwork_path, "rb") as f:
                body_parts.append(f.read())
            body_parts.append(b"\r\n")

        # Stream file — M4A 256kbps (standard streaming)
        stream_path = params.get("stream_path")
        if stream_path and os.path.exists(stream_path):
            stream_filename = os.path.basename(stream_path)
            body_parts.append(f"--{boundary}\r\n".encode())
            body_parts.append(
                f'Content-Disposition: form-data; name="stream_file"; filename="{stream_filename}"\r\n'.encode()
            )
            body_parts.append(b"Content-Type: audio/mp4\r\n\r\n")
            with open(stream_path, "rb") as f:
                body_parts.append(f.read())
            body_parts.append(b"\r\n")

        # Stream file low — M4A 128kbps (mobile / free tier)
        stream_low_path = params.get("stream_low_path")
        if stream_low_path and os.path.exists(stream_low_path):
            stream_low_filename = os.path.basename(stream_low_path)
            body_parts.append(f"--{boundary}\r\n".encode())
            body_parts.append(
                f'Content-Disposition: form-data; name="stream_file_low"; filename="{stream_low_filename}"\r\n'.encode()
            )
            body_parts.append(b"Content-Type: audio/mp4\r\n\r\n")
            with open(stream_low_path, "rb") as f:
                body_parts.append(f.read())
            body_parts.append(b"\r\n")

        body_parts.append(f"--{boundary}--\r\n".encode())

        body = b"".join(body_parts)

        server_label = _publish_server_url().replace("https://", "").replace("http://", "")
        _progress(request_id, "upload", 30, f"Uploading to {server_label}...")

        bridge_url = f"{_publish_server_url()}/api/studio-bridge/publish"

        req = urllib.request.Request(
            bridge_url,
            data=body,
            headers=_bridge_headers(f"multipart/form-data; boundary={boundary}", access_token=access_token),
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error(
                    "AUTH_FAILED",
                    f"Authentication failed ({e.code}): {resp_body}",
                    step="upload",
                )
            else:
                _raise_user_error(
                    "SERVER_ERROR",
                    f"Server returned {e.code}: {resp_body}",
                    fix="Check your internet connection and try again",
                    step="upload",
                )
        except urllib.error.URLError as e:
            _raise_user_error(
                "NETWORK_ERROR",
                f"Network error: {e.reason}",
                fix="Check your internet connection and try again",
                step="upload",
            )
        except Exception as e:
            _raise_user_error(
                "PUBLISH_FAILED",
                f"Upload failed: {e}",
                step="upload",
            )
        finally:
            # Clean up temp audio files
            for temp_path in (audio_path, params.get("stream_path"), params.get("stream_low_path")):
                if temp_path and os.path.exists(temp_path):
                    try:
                        os.unlink(temp_path)
                    except OSError:
                        pass

        resp_result = resp_data.get("data", {})
        track_id = resp_result.get("trackId", "")
        track_slug = resp_result.get("trackSlug", "")
        track_url = f"{_publish_server_url()}/track/{track_slug}" if track_slug else ""
        isrc = resp_result.get("isrc", "")

        _progress(request_id, "upload", 100, f"Published: {track_url}")

        result_data: Dict[str, Any] = {
            "success": True,
            "track_id": str(track_id),
            "track_slug": track_slug,
            "url": track_url,
        }
        if isrc:
            result_data["isrc"] = isrc
        # Extended ISRC fields from server
        for isrc_field in ("isrcFormatted", "isrcSource", "isrcError"):
            val = resp_result.get(isrc_field)
            if val:
                result_data[isrc_field] = val

        return {"result": result_data}

    # ── Fingerprinting ──────────────────────────────────────────────

    if method == "compute_fingerprint":
        audio_path = params.get("audio_path")
        if not audio_path:
            raise RPCError(-32602, "Missing required parameter: audio_path")

        fpcalc_bin = shutil.which("fpcalc")
        if fpcalc_bin is None:
            return {"result": {"fingerprint": None, "duration": None, "available": False}}

        if not os.path.exists(audio_path):
            _raise_user_error(
                "FINGERPRINT_FAILED",
                f"Audio file not found: {audio_path}",
                step="fingerprint",
            )

        try:
            fp_result = subprocess.run(
                [fpcalc_bin, "-json", audio_path],
                capture_output=True,
                text=True,
                timeout=60,
            )
            if fp_result.returncode != 0:
                logger.warning("fpcalc failed: %s", fp_result.stderr.strip())
                return {"result": {"fingerprint": None, "duration": None, "available": True, "error": fp_result.stderr.strip()[:200]}}

            fp_data = json.loads(fp_result.stdout)
            return {
                "result": {
                    "fingerprint": fp_data.get("fingerprint"),
                    "duration": fp_data.get("duration"),
                    "available": True,
                }
            }
        except subprocess.TimeoutExpired:
            logger.warning("fpcalc timed out for %s", audio_path)
            return {"result": {"fingerprint": None, "duration": None, "available": True, "error": "fpcalc timed out"}}
        except Exception as e:
            logger.warning("Fingerprint computation failed: %s", e)
            return {"result": {"fingerprint": None, "duration": None, "available": True, "error": str(e)[:200]}}

    if method == "fingerprint_lookup":
        fingerprint = params.get("fingerprint")
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        if not fingerprint or not access_token:
            raise RPCError(-32602, "Missing required parameters: fingerprint, access_token")

        lookup_url = f"{_publish_server_url()}/api/studio-bridge/fingerprint-lookup"

        body_dict: Dict[str, Any] = {"fingerprint": fingerprint}
        # Server extracts user identity from JWT — no need to send keycloak_id
        body = json.dumps(body_dict).encode()
        req = urllib.request.Request(
            lookup_url,
            data=body,
            headers=_bridge_headers("application/json", access_token=access_token),
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="fingerprint_lookup")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="fingerprint_lookup")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="fingerprint_lookup")

    # ── Provenance Certificates ──────────────────────────────────

    if method == "fetch_provenance":
        track_id = params.get("track_id")
        if not track_id:
            raise RPCError(-32602, "Missing required parameter: track_id")

        url = f"{_publish_server_url()}/api/tracks/{track_id}/provenance"
        req = urllib.request.Request(url, method="GET")

        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return {"result": {"status": "not_found"}}
            resp_body = e.read().decode()[:300] if e.fp else ""
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="provenance")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="provenance")

    # ── Catalogue Management ─────────────────────────────────────

    if method == "fetch_catalogue":
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        if not access_token:
            raise RPCError(-32602, "Not authenticated — sign in via the Publisher tab")

        offset = int(params.get("offset", 0))
        limit = int(params.get("limit", 50))

        query_params: Dict[str, Any] = {"offset": offset, "limit": limit}
        # Server extracts user identity from JWT — no need to send keycloak_id
        query = urllib.parse.urlencode(query_params)
        catalogue_url = f"{_publish_server_url()}/api/studio-bridge/catalogue?{query}"

        req = urllib.request.Request(
            catalogue_url,
            headers=_bridge_headers(access_token=access_token),
            method="GET",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="catalogue")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="catalogue")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="catalogue")

    if method == "update_published_track":
        track_id = params.get("track_id")
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        if not track_id or not access_token:
            raise RPCError(-32602, "Missing required parameters: track_id, access_token")

        update_url = f"{_publish_server_url()}/api/studio-bridge/tracks/{track_id}"
        artwork_path = params.get("artwork_path")

        # All supported PATCH fields
        _patch_fields = (
            "title", "genre", "subgenre", "artist", "album", "bpm", "musical_key",
            "lyrics", "lyrics_lrc", "artist_profile_id", "mood", "energy",
            "tags", "language", "backstory", "backstory_visibility",
            "description", "studio_track_id", "parent_track_id", "visibility",
            "explicit", "credits",
        )

        # If artwork is provided, use multipart/form-data
        if artwork_path and os.path.exists(artwork_path):
            boundary = f"----MajikStudioBridge{uuid.uuid4().hex}"
            body_parts: list[bytes] = []

            # Text fields
            form_fields: Dict[str, str] = {}
            for field in _patch_fields:
                val = params.get(field)
                if val is not None:
                    form_fields[field] = str(val)

            for field_name, field_value in form_fields.items():
                body_parts.append(f"--{boundary}\r\n".encode())
                body_parts.append(
                    f'Content-Disposition: form-data; name="{field_name}"\r\n\r\n'.encode()
                )
                body_parts.append(f"{field_value}\r\n".encode())

            # Artwork file
            artwork_filename = os.path.basename(artwork_path)
            ext = os.path.splitext(artwork_filename)[1].lower()
            content_type = {
                ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                ".png": "image/png", ".webp": "image/webp",
            }.get(ext, "image/jpeg")
            body_parts.append(f"--{boundary}\r\n".encode())
            body_parts.append(
                f'Content-Disposition: form-data; name="artwork"; filename="{artwork_filename}"\r\n'.encode()
            )
            body_parts.append(f"Content-Type: {content_type}\r\n\r\n".encode())
            with open(artwork_path, "rb") as f:
                body_parts.append(f.read())
            body_parts.append(b"\r\n")
            body_parts.append(f"--{boundary}--\r\n".encode())

            body = b"".join(body_parts)
            req = urllib.request.Request(
                update_url,
                data=body,
                headers=_bridge_headers(f"multipart/form-data; boundary={boundary}", access_token=access_token),
                method="PATCH",
            )
        else:
            # JSON-only update (no artwork)
            body_dict: Dict[str, Any] = {}
            for field in _patch_fields:
                val = params.get(field)
                if val is not None:
                    body_dict[field] = val

            body = json.dumps(body_dict).encode()
            req = urllib.request.Request(
                update_url,
                data=body,
                headers=_bridge_headers("application/json", access_token=access_token),
                method="PATCH",
            )

        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="update_track")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="update_track")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="update_track")

    if method == "fetch_creator_sales":
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        view = params.get("view", "summary")
        period = params.get("period", "month")
        if not access_token:
            raise RPCError(-32602, "Not authenticated — sign in via the Publisher tab")

        query_parts = [f"view={view}", f"period={period}"]
        url = f"{_publish_server_url()}/api/studio-bridge/creator/sales?{'&'.join(query_parts)}"
        req = urllib.request.Request(
            url,
            headers=_bridge_headers(access_token=access_token),
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="creator_sales")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="creator_sales")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="creator_sales")

    if method == "fetch_creator_earnings":
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        view = params.get("view", "summary")
        if not access_token:
            raise RPCError(-32602, "Not authenticated — sign in via the Publisher tab")

        query_parts = [f"view={view}"]
        url = f"{_publish_server_url()}/api/studio-bridge/creator/earnings?{'&'.join(query_parts)}"
        req = urllib.request.Request(
            url,
            headers=_bridge_headers(access_token=access_token),
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="creator_earnings")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="creator_earnings")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="creator_earnings")

    if method == "fetch_creator_catalog":
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        view = params.get("view", "summary")
        query = params.get("q", "")
        status = params.get("status", "")
        page = int(params.get("page", 1))
        limit = int(params.get("limit", 50))
        if not access_token:
            raise RPCError(-32602, "Not authenticated — sign in via the Publisher tab")

        url_params = f"view={view}&page={page}&limit={limit}"
        if query:
            url_params += f"&q={urllib.parse.quote(query)}"
        if status:
            url_params += f"&status={urllib.parse.quote(status)}"
        url = f"{_publish_server_url()}/api/studio-bridge/creator/catalog?{url_params}"
        req = urllib.request.Request(
            url,
            headers=_bridge_headers(access_token=access_token),
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="creator_catalog")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="creator_catalog")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="creator_catalog")

    if method == "file_dmca_claim":
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        track_id = params.get("track_id")
        reason = params.get("reason", "")
        claimant_name = params.get("claimant_name", "")
        claimant_email = params.get("claimant_email", "")
        provenance_cert_id = params.get("provenance_cert_id", "")
        evidence_urls = params.get("evidence_urls", [])
        if not access_token or not track_id:
            raise RPCError(-32602, "Missing required parameters: access_token, track_id")
        if not claimant_name or not claimant_email:
            raise RPCError(-32602, "Missing required parameters: claimant_name, claimant_email")

        url = f"{_publish_server_url()}/api/dmca"
        body_data: Dict[str, Any] = {
            "trackId": track_id,
            "reason": reason,
            "claimantName": claimant_name,
            "claimantEmail": claimant_email,
        }
        if provenance_cert_id:
            body_data["provenanceCertId"] = provenance_cert_id
        if evidence_urls:
            body_data["evidenceUrls"] = evidence_urls
        body = json.dumps(body_data).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers=_bridge_headers("application/json", access_token=access_token),
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="dmca")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="dmca")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="dmca")

    if method == "unpublish_track":
        track_id = params.get("track_id")
        keycloak_id = params.get("keycloak_id")
        access_token = params.get("access_token")
        if not track_id or not access_token:
            raise RPCError(-32602, "Missing required parameters: track_id, access_token")

        query_params: Dict[str, Any] = {}
        # Server extracts user identity from JWT — no need to send keycloak_id
        query = urllib.parse.urlencode(query_params) if query_params else ""
        delete_url = f"{_publish_server_url()}/api/studio-bridge/tracks/{track_id}"
        if query:
            delete_url += f"?{query}"

        req = urllib.request.Request(
            delete_url,
            headers=_bridge_headers(access_token=access_token),
            method="DELETE",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code in (401, 403):
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="unpublish")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="unpublish")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="unpublish")

    # ── LRC Lyrics Timestamp Generation ─────────────────────────────

    if method == "generate_lyrics_timestamps":
        audio_path = params.get("audio_path")
        lyrics_text = params.get("lyrics")
        output_path = params.get("output_path")

        if not audio_path:
            raise RPCError(-32602, "Missing required parameter: audio_path")
        if not lyrics_text or not lyrics_text.strip():
            raise RPCError(-32602, "Missing or empty required parameter: lyrics")
        if not output_path:
            raise RPCError(-32602, "Missing required parameter: output_path")
        if not os.path.exists(audio_path):
            _raise_user_error(
                "LRC_GENERATION_FAILED",
                f"Audio file not found: {audio_path}",
                fix="Check that the audio file exists and try again",
                step="lrc_generation",
            )

        request_id = request.get("id")
        _progress(request_id, "lrc", 5, "Loading forced alignment model (first run downloads ~300MB)...")

        try:
            import torch
            import torchaudio

            # Load the MMS forced alignment bundle (downloads on first use)
            bundle = torchaudio.pipelines.MMS_FA
            _progress(request_id, "lrc", 15, "Loading alignment model...")
            device = torch.device("cpu")  # Use CPU — MPS is unreliable for wav2vec2
            model = bundle.get_model().to(device)
            tokenizer = bundle.get_tokenizer()
            aligner = bundle.get_aligner()

            # Load and resample audio to 16kHz (required by MMS_FA)
            _progress(request_id, "lrc", 25, "Loading audio...")
            waveform, sample_rate = torchaudio.load(audio_path)
            # Mix to mono if stereo
            if waveform.size(0) > 1:
                waveform = waveform.mean(dim=0, keepdim=True)
            if sample_rate != bundle.sample_rate:
                waveform = torchaudio.functional.resample(waveform, sample_rate, bundle.sample_rate)
            waveform = waveform.to(device)

            # Clean lyrics: remove section markers like [Verse], [Chorus], etc.
            section_marker_re = re.compile(r"^\s*\[.*?\]\s*$")
            raw_lines = lyrics_text.strip().splitlines()
            # Build list of (original_line, cleaned_line_for_alignment)
            line_pairs = []
            for raw_line in raw_lines:
                stripped = raw_line.strip()
                if not stripped:
                    continue  # Skip empty lines
                if section_marker_re.match(stripped):
                    # Section marker — include in LRC output but don't align
                    line_pairs.append((stripped, None))
                else:
                    # Clean the line for alignment: keep only characters the tokenizer
                    # can handle (letters, spaces). MMS_FA works on normalized text.
                    cleaned = re.sub(r"[^a-zA-Z\s']", "", stripped).strip()
                    if cleaned:
                        line_pairs.append((stripped, cleaned))
                    else:
                        # Line has no alignable characters (e.g., all punctuation)
                        line_pairs.append((stripped, None))

            alignable_lines = [(i, pair) for i, pair in enumerate(line_pairs) if pair[1] is not None]

            if not alignable_lines:
                _raise_user_error(
                    "LRC_GENERATION_FAILED",
                    "No alignable lyrics lines found after cleaning",
                    fix="Ensure the lyrics contain actual words, not just section markers.",
                    step="lrc_generation",
                )

            # Get emission probabilities from the full audio
            _progress(request_id, "lrc", 35, "Computing alignment emissions...")
            with torch.no_grad():
                emission, _ = model(waveform)

            # Ratio for converting frame indices to sample indices
            num_frames = emission.size(1)
            num_samples = waveform.size(1)
            ratio = num_samples / num_frames

            # Build the full text to align (all lines joined)
            # MMS_FA tokenizer expects a list of words, not a string
            full_text = " ".join(pair[1] for _, pair in alignable_lines).lower()
            words = full_text.split()

            _progress(request_id, "lrc", 50, "Tokenizing lyrics...")
            tokens = tokenizer(words)

            _progress(request_id, "lrc", 60, "Running forced alignment...")
            token_spans = aligner(emission[0], tokens)

            # Map word indices to lines
            line_first_word_idx = []
            word_offset = 0
            for idx, (_, pair) in enumerate(alignable_lines):
                line_first_word_idx.append(word_offset)
                word_count = len(pair[1].split())
                word_offset += word_count

            lrc_entries = []  # (timestamp_seconds, original_line)

            _progress(request_id, "lrc", 75, "Computing line timestamps...")

            for line_idx, (global_idx, pair) in enumerate(alignable_lines):
                original_line = pair[0]
                word_idx = line_first_word_idx[line_idx] if line_idx < len(line_first_word_idx) else len(token_spans)
                if word_idx < len(token_spans) and len(token_spans[word_idx]) > 0:
                    first_char_span = token_spans[word_idx][0]
                    start_frame = first_char_span.start if hasattr(first_char_span, "start") else (first_char_span[0] if isinstance(first_char_span, (list, tuple)) else 0)
                    timestamp = (start_frame * ratio) / bundle.sample_rate
                    lrc_entries.append((timestamp, original_line))
                else:
                    # Fallback: no span available, estimate from position
                    total_duration = num_samples / bundle.sample_rate
                    estimated_time = (line_idx / max(len(alignable_lines), 1)) * total_duration
                    lrc_entries.append((estimated_time, original_line))

            # Also insert section markers at appropriate positions
            # by giving them the same timestamp as the next alignable line
            _progress(request_id, "lrc", 85, "Generating LRC file...")
            final_lrc_entries = []
            alignable_idx = 0
            alignable_timestamps = {global_idx: ts for (global_idx, _), (ts, _) in zip(alignable_lines, lrc_entries)}

            for global_idx, (original_line, cleaned) in enumerate(line_pairs):
                if cleaned is not None:
                    # This is an alignable line — use its computed timestamp
                    if global_idx in alignable_timestamps:
                        final_lrc_entries.append((alignable_timestamps[global_idx], original_line))
                else:
                    # Section marker or non-alignable line
                    # Find the next alignable line's timestamp
                    next_ts = None
                    for future_idx in range(global_idx + 1, len(line_pairs)):
                        if future_idx in alignable_timestamps:
                            next_ts = alignable_timestamps[future_idx]
                            break
                    if next_ts is not None:
                        # Place section marker slightly before the next line
                        final_lrc_entries.append((max(0, next_ts - 0.5), original_line))
                    elif final_lrc_entries:
                        # No next line — place after the last entry
                        final_lrc_entries.append((final_lrc_entries[-1][0] + 1.0, original_line))
                    else:
                        # Very first entry and no alignable lines after it
                        final_lrc_entries.append((0.0, original_line))

            # Write LRC file
            os.makedirs(os.path.dirname(output_path), exist_ok=True)
            with open(output_path, "w", encoding="utf-8") as f:
                for timestamp, line in final_lrc_entries:
                    minutes = int(timestamp) // 60
                    seconds = timestamp - (minutes * 60)
                    f.write(f"[{minutes:02d}:{seconds:05.2f}]{line}\n")

            _progress(request_id, "lrc", 100, "LRC file generated")
            logger.info("Generated LRC file: %s (%d lines)", output_path, len(final_lrc_entries))

            return {
                "result": {
                    "status": "ok",
                    "output_path": output_path,
                    "line_count": len(final_lrc_entries),
                }
            }

        except ImportError as e:
            logger.warning("torchaudio not available for LRC generation: %s", e)
            _raise_user_error(
                "LRC_GENERATION_FAILED",
                "torchaudio is not installed. Required for lyrics timestamp generation.",
                fix="Ensure torch and torchaudio are installed in the Python environment.",
                step="lrc_generation",
                detail=str(e),
            )
        except Exception as e:
            logger.exception("LRC generation failed for: %s", audio_path)
            _raise_user_error(
                "LRC_GENERATION_FAILED",
                f"Lyrics timestamp generation failed: {e}",
                fix="Try again. If the problem persists, check the audio file and lyrics.",
                step="lrc_generation",
                detail=str(e),
            )

    # ── Library listing methods (for artwork generator & external tool integration) ──

    if method == "list_library_tracks":
        library_json = os.path.join(DEFAULT_APP_SUPPORT_PATH, "library.json")
        if not os.path.exists(library_json):
            return {"result": {"tracks": []}}
        with open(library_json, "r", encoding="utf-8") as f:
            tracks = json.load(f)
        # Return metadata relevant for artwork/external tools
        result_tracks = []
        for t in tracks:
            result_tracks.append({
                "id": t.get("id", ""),
                "title": t.get("title", ""),
                "artist": t.get("artist", ""),
                "album": t.get("album", ""),
                "genre": t.get("genre", ""),
                "bpm": t.get("bpm", 0),
                "musicalKey": t.get("musicalKey", ""),
                "duration": t.get("duration", 0),
                "rating": t.get("rating", 0),
                "lyrics": t.get("lyrics", ""),
                "audioFileName": t.get("audioFileName", ""),
                "customArtworkFileName": t.get("customArtworkFileName", ""),
            })
        return {"result": {"tracks": result_tracks, "count": len(result_tracks)}}

    if method == "list_library_albums":
        library_json = os.path.join(DEFAULT_APP_SUPPORT_PATH, "library.json")
        if not os.path.exists(library_json):
            return {"result": {"albums": []}}
        with open(library_json, "r", encoding="utf-8") as f:
            tracks = json.load(f)
        albums: Dict[str, Any] = {}
        for t in tracks:
            album_name = t.get("album", "")
            if not album_name:
                continue
            if album_name not in albums:
                albums[album_name] = {
                    "name": album_name,
                    "artist": t.get("artist", ""),
                    "genre": t.get("genre", ""),
                    "trackCount": 0,
                    "artworkFileName": t.get("artworkFileName", ""),
                }
            albums[album_name]["trackCount"] += 1
        return {"result": {"albums": list(albums.values()), "count": len(albums)}}

    if method == "list_library_artists":
        library_json = os.path.join(DEFAULT_APP_SUPPORT_PATH, "library.json")
        if not os.path.exists(library_json):
            return {"result": {"artists": []}}
        with open(library_json, "r", encoding="utf-8") as f:
            tracks = json.load(f)
        artists: Dict[str, Any] = {}
        for t in tracks:
            artist_name = t.get("artist", "")
            if not artist_name:
                continue
            if artist_name not in artists:
                artists[artist_name] = {
                    "name": artist_name,
                    "trackCount": 0,
                    "genres": set(),
                    "photoFileName": t.get("photoFileName", ""),
                }
            artists[artist_name]["trackCount"] += 1
            if t.get("genre"):
                artists[artist_name]["genres"].add(t["genre"])
        # Convert sets to lists for JSON serialization
        for a in artists.values():
            a["genres"] = sorted(a["genres"])
        return {"result": {"artists": list(artists.values()), "count": len(artists)}}

    # ── Artwork assignment methods ──

    if method == "set_track_artwork":
        track_id = params.get("track_id")
        artwork_path = params.get("artwork_path")
        if not track_id:
            raise RPCError(-32602, "Missing required param: track_id")
        if not artwork_path or not os.path.exists(artwork_path):
            raise RPCError(-32602, "Missing or invalid artwork_path")

        library_json = os.path.join(DEFAULT_APP_SUPPORT_PATH, "library.json")
        if not os.path.exists(library_json):
            raise RPCError(-32010, "Library not found")

        artwork_dir = os.path.join(DEFAULT_APP_SUPPORT_PATH, "Artwork")
        os.makedirs(artwork_dir, exist_ok=True)

        # Copy artwork to the Artwork directory
        ext = os.path.splitext(artwork_path)[1] or ".jpg"
        dest_name = f"track-{track_id}{ext}"
        dest_path = os.path.join(artwork_dir, dest_name)
        shutil.copy2(artwork_path, dest_path)

        # Update library.json
        with open(library_json, "r", encoding="utf-8") as f:
            tracks = json.load(f)
        found = False
        for t in tracks:
            if t.get("id") == track_id:
                t["customArtworkFileName"] = dest_name
                found = True
                break
        if not found:
            raise RPCError(-32010, f"Track not found: {track_id}")
        with open(library_json, "w", encoding="utf-8") as f:
            json.dump(tracks, f, indent=2, ensure_ascii=False)
        return {"result": {"status": "ok", "artworkFileName": dest_name}}

    if method == "set_album_artwork":
        album_name = params.get("album")
        artwork_path = params.get("artwork_path")
        if not album_name:
            raise RPCError(-32602, "Missing required param: album")
        if not artwork_path or not os.path.exists(artwork_path):
            raise RPCError(-32602, "Missing or invalid artwork_path")

        library_json = os.path.join(DEFAULT_APP_SUPPORT_PATH, "library.json")
        if not os.path.exists(library_json):
            raise RPCError(-32010, "Library not found")

        artwork_dir = os.path.join(DEFAULT_APP_SUPPORT_PATH, "Artwork")
        os.makedirs(artwork_dir, exist_ok=True)

        ext = os.path.splitext(artwork_path)[1] or ".jpg"
        safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", album_name)
        dest_name = f"album-{safe_name}{ext}"
        dest_path = os.path.join(artwork_dir, dest_name)
        shutil.copy2(artwork_path, dest_path)

        # Update all tracks in this album
        with open(library_json, "r", encoding="utf-8") as f:
            tracks = json.load(f)
        updated = 0
        for t in tracks:
            if t.get("album") == album_name:
                t["artworkFileName"] = dest_name
                updated += 1
        with open(library_json, "w", encoding="utf-8") as f:
            json.dump(tracks, f, indent=2, ensure_ascii=False)
        return {"result": {"status": "ok", "artworkFileName": dest_name, "tracksUpdated": updated}}

    if method == "set_artist_artwork":
        artist_name = params.get("artist")
        artwork_path = params.get("artwork_path")
        if not artist_name:
            raise RPCError(-32602, "Missing required param: artist")
        if not artwork_path or not os.path.exists(artwork_path):
            raise RPCError(-32602, "Missing or invalid artwork_path")

        library_json = os.path.join(DEFAULT_APP_SUPPORT_PATH, "library.json")
        if not os.path.exists(library_json):
            raise RPCError(-32010, "Library not found")

        artwork_dir = os.path.join(DEFAULT_APP_SUPPORT_PATH, "Artwork")
        os.makedirs(artwork_dir, exist_ok=True)

        ext = os.path.splitext(artwork_path)[1] or ".jpg"
        safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", artist_name)
        dest_name = f"artist-{safe_name}{ext}"
        dest_path = os.path.join(artwork_dir, dest_name)
        shutil.copy2(artwork_path, dest_path)

        # Update all tracks by this artist
        with open(library_json, "r", encoding="utf-8") as f:
            tracks = json.load(f)
        updated = 0
        for t in tracks:
            if t.get("artist") == artist_name:
                t["photoFileName"] = dest_name
                updated += 1
        with open(library_json, "w", encoding="utf-8") as f:
            json.dump(tracks, f, indent=2, ensure_ascii=False)
        return {"result": {"status": "ok", "artworkFileName": dest_name, "tracksUpdated": updated}}

    # ── Songwriting bridge import ──

    if method == "import_track":
        title = params.get("title")
        if not title:
            raise RPCError(-32602, "Missing required param: title")

        library_json = os.path.join(DEFAULT_APP_SUPPORT_PATH, "library.json")
        audio_dir = os.path.join(DEFAULT_APP_SUPPORT_PATH, "Audio")

        # Load existing library
        tracks = []
        if os.path.exists(library_json):
            with open(library_json, "r", encoding="utf-8") as f:
                tracks = json.load(f)

        # Generate a new track ID
        track_id = str(uuid.uuid4())

        # Extract optional fields
        artist = params.get("artist", "")
        album = params.get("album", "")
        genre = params.get("genre", "")
        lyrics = params.get("lyrics", "")
        bpm = params.get("bpm", 0)
        musical_key = params.get("musicalKey", params.get("key", ""))
        duration = params.get("duration", 0)

        # Handle audio file if provided
        audio_file_name = ""
        audio_url = params.get("audio_url")
        audio_path = params.get("audio_path")

        if audio_path and os.path.exists(audio_path):
            # Copy local audio file to library
            safe_artist = re.sub(r"[^a-zA-Z0-9_ -]", "", artist or "Unknown")
            safe_album = re.sub(r"[^a-zA-Z0-9_ -]", "", album or "Singles")
            dest_dir = os.path.join(audio_dir, safe_artist, safe_album)
            os.makedirs(dest_dir, exist_ok=True)
            ext = os.path.splitext(audio_path)[1] or ".wav"
            safe_title = re.sub(r"[^a-zA-Z0-9_ -]", "", title)
            dest_file = f"{safe_title}{ext}"
            dest_path = os.path.join(dest_dir, dest_file)
            shutil.copy2(audio_path, dest_path)
            audio_file_name = os.path.join(safe_artist, safe_album, dest_file)

        elif audio_url:
            # Download audio from URL
            safe_artist = re.sub(r"[^a-zA-Z0-9_ -]", "", artist or "Unknown")
            safe_album = re.sub(r"[^a-zA-Z0-9_ -]", "", album or "Singles")
            dest_dir = os.path.join(audio_dir, safe_artist, safe_album)
            os.makedirs(dest_dir, exist_ok=True)
            safe_title = re.sub(r"[^a-zA-Z0-9_ -]", "", title)
            # Detect extension from URL or default to .wav
            url_ext = os.path.splitext(urllib.parse.urlparse(audio_url).path)[1]
            ext = url_ext if url_ext in (".wav", ".mp3", ".flac", ".m4a") else ".wav"
            dest_file = f"{safe_title}{ext}"
            dest_path = os.path.join(dest_dir, dest_file)
            try:
                urllib.request.urlretrieve(audio_url, dest_path)
                audio_file_name = os.path.join(safe_artist, safe_album, dest_file)
            except Exception as dl_err:
                logger.warning("Failed to download audio from %s: %s", audio_url, dl_err)

        # Build track entry
        new_track = {
            "id": track_id,
            "title": title,
            "artist": artist,
            "album": album,
            "genre": genre,
            "lyrics": lyrics,
            "bpm": bpm,
            "musicalKey": musical_key,
            "duration": duration,
            "rating": 0,
            "audioFileName": audio_file_name,
            "customArtworkFileName": "",
            "createdAt": "",
        }

        tracks.append(new_track)
        with open(library_json, "w", encoding="utf-8") as f:
            json.dump(tracks, f, indent=2, ensure_ascii=False)

        return {"result": {"status": "ok", "track_id": track_id, "title": title}}

    # ── Art Studio integration ──

    if method == "art_studio_health":
        try:
            req = urllib.request.Request("http://localhost:8420/health", method="GET")
            req.add_header("Accept", "application/json")
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return {"result": {"available": True, "version": data.get("version", "unknown")}}
        except Exception as exc:
            logger.debug("Art Studio health check failed: %s", exc)
            return {"result": {"available": False, "error": str(exc)}}

    if method == "generate_track_artwork":
        title = params.get("title", "")
        artist = params.get("artist", "")
        album = params.get("album")
        genre = params.get("genre")
        prompt = params.get("prompt")
        track_id = params.get("track_id", "")
        if not title:
            raise RPCError(-32602, "Missing required param: title")

        body = {"title": title, "artist": artist, "type": "track"}
        if album:
            body["album"] = album
        if genre:
            body["genre"] = genre
        if prompt:
            body["prompt"] = prompt

        result = _art_studio_generate("/studio/track-artwork", body)
        # Copy result image to Artwork directory
        if result.get("image_path"):
            artwork_dir = os.path.join(DEFAULT_APP_SUPPORT_PATH, "Artwork")
            os.makedirs(artwork_dir, exist_ok=True)
            ext = os.path.splitext(result["image_path"])[1] or ".png"
            dest_name = f"artstudio-track-{track_id or 'unknown'}{ext}"
            dest_path = os.path.join(artwork_dir, dest_name)
            shutil.copy2(result["image_path"], dest_path)
            result["local_path"] = dest_path
        return {"result": result}

    if method == "generate_album_artwork":
        title = params.get("title", "")
        artist = params.get("artist", "")
        genre = params.get("genre")
        track_count = params.get("track_count")
        prompt = params.get("prompt")
        if not title:
            raise RPCError(-32602, "Missing required param: title")

        body = {"title": title, "artist": artist, "type": "album"}
        if genre:
            body["genre"] = genre
        if track_count:
            body["track_count"] = track_count
        if prompt:
            body["prompt"] = prompt

        result = _art_studio_generate("/studio/album-artwork", body)
        if result.get("image_path"):
            artwork_dir = os.path.join(DEFAULT_APP_SUPPORT_PATH, "Artwork")
            os.makedirs(artwork_dir, exist_ok=True)
            ext = os.path.splitext(result["image_path"])[1] or ".png"
            safe_title = "".join(c for c in title if c.isalnum() or c in " -_")[:50].strip()
            dest_name = f"artstudio-album-{safe_title}{ext}"
            dest_path = os.path.join(artwork_dir, dest_name)
            shutil.copy2(result["image_path"], dest_path)
            result["local_path"] = dest_path
        return {"result": result}

    if method == "generate_artist_artwork":
        name = params.get("name", "")
        role = params.get("role")
        prompt = params.get("prompt")
        if not name:
            raise RPCError(-32602, "Missing required param: name")

        body = {"name": name, "type": "artist"}
        if role:
            body["role"] = role
        if prompt:
            body["prompt"] = prompt

        result = _art_studio_generate("/studio/artist-artwork", body)
        if result.get("image_path"):
            artwork_dir = os.path.join(DEFAULT_APP_SUPPORT_PATH, "Artwork")
            os.makedirs(artwork_dir, exist_ok=True)
            ext = os.path.splitext(result["image_path"])[1] or ".png"
            safe_name = "".join(c for c in name if c.isalnum() or c in " -_")[:50].strip()
            dest_name = f"artstudio-artist-{safe_name}{ext}"
            dest_path = os.path.join(artwork_dir, dest_name)
            shutil.copy2(result["image_path"], dest_path)
            result["local_path"] = dest_path
        return {"result": result}

    if method == "tag_audio_metadata":
        file_path = params.get("file_path", "")
        metadata = params.get("metadata", {})
        if not file_path or not os.path.exists(file_path):
            raise RPCError(-32602, "File not found or not specified")

        import json as _json

        # Write metadata as JSON sidecar
        sidecar_path = file_path + ".meta.json"
        try:
            with open(sidecar_path, "w", encoding="utf-8") as f:
                _json.dump(metadata, f, indent=2, default=str)
        except Exception as e:
            logger.warning("Failed to write metadata sidecar: %s", e)

        # Try mutagen for embedded tags
        try:
            import mutagen
            audio = mutagen.File(file_path, easy=True)
            if audio is not None:
                for key, value in metadata.items():
                    try:
                        audio[key] = value
                    except Exception:
                        pass
                audio.save()
        except ImportError:
            pass  # mutagen not available, sidecar is sufficient
        except Exception as e:
            logger.warning("Failed to embed tags via mutagen: %s", e)

        return {"result": {"success": True, "path": file_path}}

    if method == "shutdown":
        return {"result": {"status": "shutting_down"}}

    raise RPCError(-32601, f"Method not found: {method}")


def process_line(line: str) -> Dict[str, Any]:
    try:
        request = json.loads(line)
    except json.JSONDecodeError as exc:
        raise RPCError(-32700, "Parse error", {"detail": str(exc)})

    if not isinstance(request, dict):
        raise RPCError(-32600, "Invalid Request")

    if request.get("jsonrpc") != "2.0":
        raise RPCError(-32600, "Invalid Request: jsonrpc must be '2.0'")

    request_id = request.get("id")
    response: Dict[str, Any] = {"jsonrpc": "2.0", "id": request_id}

    try:
        response.update(handle_request(request))
    except RPCError as exc:
        return _json_error_response(request_id, exc)
    except Exception as exc:  # noqa: BLE001
        logger.exception("Unhandled error")
        structured = _categorize_exception(exc)
        return _json_error_response(
            request_id,
            RPCError(-32010, structured["message"], structured),
        )

    return response


def _write_response(response: Dict[str, Any]) -> None:
    """Thread-safe write of a JSON-RPC response to stdout."""
    payload = json.dumps(response, ensure_ascii=False)
    with _stdout_lock:
        sys.stdout.write(payload + "\n")
        sys.stdout.flush()


# Methods that the reader thread can handle immediately (while the main thread
# is busy with a long-running generation).  These must be fast and thread-safe.
_FAST_METHODS = {"cancel_generation"}


def run() -> None:
    configure_logging()
    logger.info("Majik RPC server started")

    import queue as _queue_mod
    request_queue: _queue_mod.Queue = _queue_mod.Queue()

    def _stdin_reader() -> None:
        """Background thread: reads stdin, dispatches fast commands immediately,
        queues everything else for the main thread."""
        try:
            for raw_line in sys.stdin:
                line = raw_line.strip()
                if not line:
                    continue
                # Peek at the method to decide routing
                try:
                    request = json.loads(line)
                except (json.JSONDecodeError, ValueError):
                    # Let the main thread handle parse errors
                    request_queue.put(line)
                    continue

                method = request.get("method") if isinstance(request, dict) else None

                if method in _FAST_METHODS:
                    # Handle cancel_generation directly in reader thread
                    request_id = request.get("id") if isinstance(request, dict) else None
                    try:
                        response = process_line(line)
                    except Exception as exc:
                        response = _json_error_response(request_id, RPCError(-32603, str(exc)))
                    _write_response(response)
                else:
                    request_queue.put(line)
        except Exception:
            logger.exception("stdin reader thread crashed")
        finally:
            # Always signal main thread so it never hangs
            request_queue.put(None)

    reader_thread = threading.Thread(target=_stdin_reader, daemon=True, name="rpc-stdin-reader")
    reader_thread.start()

    while True:
        line = request_queue.get()
        if line is None:
            # stdin closed
            break
        request_id: Optional[str] = None
        try:
            response = process_line(line)
            request_id = response.get("id")
        except RPCError as exc:
            response = _json_error_response(request_id, exc)
        _write_response(response)

        if response.get("result", {}).get("status") == "shutting_down":
            logger.info("Shutdown requested")
            break

    logger.info("Majik RPC server stopped")


if __name__ == "__main__":
    run()
