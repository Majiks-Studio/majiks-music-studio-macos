from __future__ import annotations

import logging
import os
import shutil
import subprocess
import sys
import errno
import threading
import gc
from pathlib import Path
from typing import Any, Dict, List, Optional

import librosa
import numpy as np
import soundfile as sf
import urllib.request
import json

from .tls import https_urlretrieve

# ---------------------------------------------------------------------------
# MPS Fallback (Apple Silicon GPU compatibility)
# ---------------------------------------------------------------------------
# ACE-Step's neural network includes convolution layers with >65536 output
# channels.  Apple's MPS backend does not support that many channels for
# certain ops and will crash at runtime.  Setting this env var tells PyTorch
# to transparently fall back to CPU for the unsupported op while keeping
# everything else on the GPU.  The perf hit is negligible (~1-2 s on a
# typical generation).  Must be set BEFORE torch is first imported.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

# ---------------------------------------------------------------------------
# MPS Cache Patch (Apple Silicon memory leak mitigation)
# ---------------------------------------------------------------------------
# ACE-Step's upstream code calls torch.cuda.empty_cache() in 6 places
# (handler.py, llm_inference.py) but that's a no-op on Apple Silicon.
# This patch makes those calls also clear MPS memory.
def _install_mps_cache_patch():
    try:
        import torch
        if not (hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache")):
            return
        _orig = torch.cuda.empty_cache
        def _patched():
            _orig()
            torch.mps.empty_cache()
        torch.cuda.empty_cache = _patched
    except Exception:
        pass

_install_mps_cache_patch()

# ---------------------------------------------------------------------------
# torchaudio.save patch (torchcodec not bundled)
# ---------------------------------------------------------------------------
# torchaudio 2.10+ rewrote save() to require torchcodec (which needs ffmpeg
# native libs we don't bundle).  We monkey-patch torchaudio.save to use
# soundfile for WAV/FLAC saving, which is all ACE-Step needs.
def _patch_torchaudio_save():
    """Replace torchaudio.save with a soundfile-backed version if torchcodec is missing."""
    try:
        import torchcodec  # noqa: F401
        return  # torchcodec available, no patch needed
    except ImportError:
        pass
    try:
        import torchaudio
        import soundfile as _sf

        _original_save = torchaudio.save

        def _patched_save(uri, src, sample_rate, channels_first=True, format=None,
                          encoding=None, bits_per_sample=None, buffer_size=4096,
                          backend=None, compression=None):
            # Determine format from file extension if not given
            if format is None and isinstance(uri, (str, os.PathLike)):
                ext = str(uri).rsplit(".", 1)[-1].lower() if "." in str(uri) else ""
                format = ext if ext else "wav"
            format = (format or "wav").lower()

            if format in ("wav", "flac"):
                # Transparent passthrough to soundfile — no normalization,
                # no subtype override. soundfile auto-selects FLOAT for
                # float32 input and PCM_16 for FLAC. This matches what
                # the original torchaudio soundfile backend does.
                data = src
                if channels_first and data.dim() == 2:
                    data = data.t()  # [channel, time] -> [time, channel]
                if data.dim() == 1:
                    data = data.unsqueeze(-1)  # [time] -> [time, 1]
                data_np = data.cpu().numpy()
                _sf.write(str(uri), data_np, sample_rate, format=format.upper())
            else:
                # Fall through to original for non-WAV/FLAC (will raise ImportError)
                _original_save(uri, src, sample_rate, channels_first=channels_first,
                               format=format, encoding=encoding,
                               bits_per_sample=bits_per_sample,
                               buffer_size=buffer_size, backend=backend,
                               compression=compression)

        torchaudio.save = _patched_save
        logging.getLogger(__name__).info(
            "Patched torchaudio.save to use soundfile (torchcodec not available)")
    except ImportError:
        logging.getLogger(__name__).warning(
            "torchaudio not available for patching; will retry when needed")

# Lazy import torch - only needed for actual generation, not for listing models
torch = None

def _patch_vq_for_meta_device():
    """Patch vector_quantize_pytorch to work with transformers 5.x meta-device init.

    transformers >= 5.0 creates models on ``torch.device("meta")`` during
    ``from_pretrained``, then materialises real weights afterwards.  This breaks
    ``vector_quantize_pytorch``'s ``ResidualFSQ`` and ``FSQ`` because they:
      1. Assert ``(levels_tensor > 1).all()`` which calls ``.item()`` on meta tensors
      2. Create non-persistent buffers (``_levels``, ``_basis``, ``implicit_codebook``)
         that are never in the state_dict and must have real values

    Fix: wrap their ``__init__`` in ``torch.device('cpu')`` so buffers get real
    values even when the outer context is meta.  All other modules stay on meta
    for proper weight loading.
    """
    try:
        import torch as _t
        from vector_quantize_pytorch import residual_fsq as _rfsq
        from vector_quantize_pytorch import finite_scalar_quantization as _fsq

        _orig_rfsq_init = _rfsq.ResidualFSQ.__init__
        _orig_fsq_init = _fsq.FSQ.__init__

        def _patched_rfsq_init(self, *args, **kwargs):
            with _t.device("cpu"):
                _orig_rfsq_init(self, *args, **kwargs)

        def _patched_fsq_init(self, *args, **kwargs):
            with _t.device("cpu"):
                _orig_fsq_init(self, *args, **kwargs)

        _rfsq.ResidualFSQ.__init__ = _patched_rfsq_init
        _fsq.FSQ.__init__ = _patched_fsq_init
        logging.getLogger(__name__).info(
            "Patched ResidualFSQ/FSQ to init on CPU (meta-device compat)")
    except Exception:
        pass  # vector_quantize_pytorch not installed – not critical


def _ensure_torch():
    """Lazily import torch when needed for generation."""
    global torch
    if torch is None:
        import torch as _torch
        torch = _torch
        _patch_torchaudio_save()
        _patch_vq_for_meta_device()
    return torch


def _get_available_ram_gb() -> float:
    """Return available (free + inactive) RAM in GB on macOS via vm_stat."""
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

logger = logging.getLogger(__name__)


class GenerationStepError(Exception):
    def __init__(
        self,
        code: str,
        step: str,
        message: str,
        fix: str,
        detail: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.step = step
        self.message = message
        self.fix = fix
        self.detail = detail


class ACEStepGenerator:
    """Real ACE-Step 1.5 music generation."""

    def __init__(self) -> None:
        self.dit_handler = None
        self.llm_handler = None
        self.current_model = None
        # Defer device detection until torch is available
        self._device = None
        self._model_lock = threading.RLock()
        self._active_generations = 0
        self._idle_unload_timer: Optional[threading.Timer] = None
        self.keep_dit_warm = os.getenv("ACE_STEP_KEEP_DIT_WARM", "0").lower() in {"1", "true", "yes", "on"}
        self.idle_unload_seconds = max(0, int(os.getenv("ACE_STEP_IDLE_UNLOAD_SECONDS", "180")))
        self.project_root = os.getenv("ACE_STEP_ROOT", str(Path.home() / "ACE-Step-1.5"))
        # Default checkpoint_dir is inside project_root/checkpoints
        default_checkpoint_dir = str(Path(self.project_root) / "checkpoints")
        self.checkpoint_dir = os.getenv("ACE_STEP_CHECKPOINT_DIR", default_checkpoint_dir)
        logger.info("ACE-Step project root: %s", self.project_root)
        logger.info(
            "ACE-Step model management: keep_dit_warm=%s, idle_unload_seconds=%s",
            self.keep_dit_warm,
            self.idle_unload_seconds,
        )

    def _clear_mlx_cache(self) -> None:
        """Clear MLX Metal cache to release GPU memory back to the system."""
        try:
            import mlx.core as mx
            if hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
                mx.metal.clear_cache()
                logger.info("MLX Metal cache cleared")
        except ImportError:
            pass
        except Exception as exc:
            logger.warning("Failed to clear MLX cache: %s", exc)

    @property
    def device(self) -> str:
        """Get the compute device, lazily detecting MPS availability.

        Respects ``ACE_STEP_FORCE_CPU=1`` for users who want to bypass MPS
        entirely (useful on low-RAM machines where unified memory pressure
        from GPU allocation can trigger swapping).
        """
        if self._device is None:
            force_cpu = os.getenv("ACE_STEP_FORCE_CPU", "0").lower() in {"1", "true", "yes", "on"}
            if force_cpu:
                self._device = "cpu"
                logger.info("ACE-Step forced to CPU by ACE_STEP_FORCE_CPU env var")
            else:
                torch_mod = _ensure_torch()
                self._device = "mps" if torch_mod.backends.mps.is_available() else "cpu"
                logger.info("ACE-Step will use device: %s", self._device)
        return self._device

    def _cancel_idle_unload(self) -> None:
        with self._model_lock:
            if self._idle_unload_timer is not None:
                self._idle_unload_timer.cancel()
                self._idle_unload_timer = None

    def _schedule_idle_unload(self) -> None:
        with self._model_lock:
            if not self.keep_dit_warm or self.idle_unload_seconds <= 0:
                return
            if self._idle_unload_timer is not None:
                self._idle_unload_timer.cancel()
            self._idle_unload_timer = threading.Timer(self.idle_unload_seconds, self._idle_unload_callback)
            self._idle_unload_timer.daemon = True
            self._idle_unload_timer.start()

    def _idle_unload_callback(self) -> None:
        with self._model_lock:
            self._idle_unload_timer = None
            if self._active_generations > 0:
                return
        logger.info("Idle timeout reached; unloading ACE-Step models")
        self.unload_models()

    def estimate_memory_requirements(self, lm_model_path: str, duration: int = 150, model_name: str = "") -> Dict[str, Any]:
        lm_requirements = {
            "acestep-5Hz-lm-0.6B": {"minimum_gb": 16, "recommended_gb": 24, "expected_peak_gb": "18-24"},
            "acestep-5Hz-lm-1.7B": {"minimum_gb": 24, "recommended_gb": 32, "expected_peak_gb": "24-34"},
            "acestep-5Hz-lm-4B": {"minimum_gb": 32, "recommended_gb": 48, "expected_peak_gb": "34-50"},
        }
        base = lm_requirements.get(lm_model_path, lm_requirements["acestep-5Hz-lm-1.7B"]).copy()
        if duration > 180:
            base["minimum_gb"] += 2
            base["recommended_gb"] += 2
        if duration > 300:
            base["minimum_gb"] += 2
            base["recommended_gb"] += 4
        # XL (4B) DiT models need ~4GB more than standard 2B models
        if "xl" in model_name.lower():
            base["minimum_gb"] += 4
            base["recommended_gb"] += 4
        base["lm_model"] = lm_model_path
        base["duration_seconds"] = int(duration)
        base["available_ram_gb"] = _get_available_ram_gb()
        return base

    def load_model(self, model_name: str = "acestep-v15-turbo", lm_model_path: str = "acestep-5Hz-lm-1.7B") -> None:
        with self._model_lock:
            self._cancel_idle_unload()
            if (
                self.dit_handler is not None
                and self.llm_handler is not None
                and self.current_model == model_name
            ):
                return

        try:
            project_root_path = Path(self.project_root)
            if not project_root_path.exists():
                raise GenerationStepError(
                    code="ACE_STEP_NOT_FOUND",
                    step="ACE-Step init",
                    message=f"ACE-Step model weights not found at {self.project_root}",
                    fix="Install ACE-Step in Settings, then try again.",
                )
            # Check for required model files (not local acestep folder - we use pip package)
            required_dirs = ["vae", "acestep-v15-turbo"]
            missing = [d for d in required_dirs if not (project_root_path / d).exists()]
            if missing:
                raise GenerationStepError(
                    code="ACE_STEP_NOT_FOUND",
                    step="ACE-Step init",
                    message=f"ACE-Step model weights missing: {', '.join(missing)}",
                    fix="Reinstall ACE-Step in Settings, then validate installation.",
                )

            # Add ACE-Step to Python path
            if self.project_root not in sys.path:
                sys.path.insert(0, self.project_root)

            # Use the original ACE-Step orchestration modules (handler, inference, llm)
            # These are the full-featured modules from ACE-Step 1.5 that include
            # 5Hz LLM Chain-of-Thought reasoning for high-quality music generation.
            from acestep.handler import AceStepHandler
            from acestep.llm_inference import LLMHandler

            logger.info("Loading ACE-Step 1.5 model with LM: %s", lm_model_path)

            # Ensure checkpoints directory structure is correct.
            # The handler expects model dirs under checkpoints/, but some installs
            # have them at the project root. Create symlinks if needed.
            checkpoints_dir = Path(self.project_root) / "checkpoints"
            checkpoints_dir.mkdir(exist_ok=True)
            for component in ["acestep-v15-turbo", "vae", "Qwen3-Embedding-0.6B"]:
                target = checkpoints_dir / component
                source = Path(self.project_root) / component
                if not target.exists() and source.exists():
                    try:
                        target.symlink_to(source)
                        logger.info("Created symlink: %s -> %s", target, source)
                    except OSError:
                        pass

            # Initialize DiT handler
            self.dit_handler = AceStepHandler()
            # Override _get_project_root to point to the user's ACE-Step installation
            # (the original code uses __file__ location which won't work when
            # handler.py is in site-packages instead of ~/ACE-Step-1.5/acestep/)
            project_root = self.project_root
            self.dit_handler._get_project_root = lambda: project_root
            use_mlx_dit = self.device == "mps"  # Native MLX diffusion on Apple Silicon
            logger.info("Initializing DiT model with %s (MLX DiT: %s)...", self.device, use_mlx_dit)
            status_msg, success = self.dit_handler.initialize_service(
                project_root=self.project_root,
                config_path=model_name,
                device=self.device,
                offload_to_cpu=True,  # Offload models to CPU when not in use (saves GPU memory)
            )
            if not success:
                raise GenerationStepError(
                    code="MODEL_NOT_FOUND",
                    step="model load",
                    message=f"Failed to initialize DiT model: {status_msg}",
                    fix="Download required model files in Settings and retry.",
                )
            logger.info("DiT model initialized (MLX DiT enabled: %s): %s", use_mlx_dit, status_msg)

            # Initialize LLM handler with specified model size
            self.llm_handler = LLMHandler()
            logger.info("Initializing 5Hz Language Model (%s) with MPS...", lm_model_path)

            # Check if model exists before trying to load
            model_path = os.path.join(self.checkpoint_dir, lm_model_path)
            if not os.path.exists(model_path):
                available_models = []
                if os.path.exists(self.checkpoint_dir):
                    available_models = [d for d in os.listdir(self.checkpoint_dir)
                                      if d.startswith("acestep-5Hz-lm-") and os.path.isdir(os.path.join(self.checkpoint_dir, d))]

                error_msg = f"❌ 5Hz LM model not found at {model_path}"
                if available_models:
                    error_msg += f"\n\n✅ Available models: {', '.join(available_models)}"
                    error_msg += f"\n\n💡 TIP: Go to Studio → ACE-Step LM and select one of the available models, or download '{lm_model_path}' from Hugging Face: https://huggingface.co/acestep/ACE-Step-1.5/tree/main"
                else:
                    error_msg += f"\n\n💡 Download ACE-Step models from: https://huggingface.co/acestep/ACE-Step-1.5/tree/main"

                raise GenerationStepError(
                    code="MODEL_NOT_FOUND",
                    step="model load",
                    message=error_msg,
                    fix="Select an available model or download the required model files.",
                )

            # Auto-copy silence_latent.pt if missing (exists in turbo dir but not always in LM dirs)
            silence_file = os.path.join(model_path, "silence_latent.pt")
            if not os.path.exists(silence_file):
                turbo_silence = os.path.join(self.checkpoint_dir, "acestep-v15-turbo", "silence_latent.pt")
                if os.path.exists(turbo_silence):
                    import shutil
                    shutil.copy2(turbo_silence, silence_file)
                    logger.info("Auto-copied silence_latent.pt from turbo dir to %s", model_path)
                else:
                    raise GenerationStepError(
                        code="MODEL_INCOMPLETE",
                        step="model load",
                        message=f"❌ silence_latent.pt missing from {model_path} and not found in turbo dir to copy.",
                        fix="Re-download ACE-Step models from https://huggingface.co/acestep/ACE-Step-1.5/tree/main",
                    )

            # LLM backend: prefer MLX on Apple Silicon (native Metal, much lower memory)
            # Fall back to PyTorch only if MLX unavailable. vllm is CUDA-only.
            force_llm_cpu = os.getenv("ACE_STEP_LLM_CPU", "0").lower() in {"1", "true", "yes"}
            lm_device = "cpu" if force_llm_cpu else self.device
            env_backend = os.getenv("ACESTEP_LM_BACKEND", "").lower()
            if env_backend in ("mlx", "pt", "vllm"):
                lm_backend = env_backend
            elif self.device == "mps":
                lm_backend = "mlx"  # Native Metal acceleration, 2-3x faster than PyTorch MPS
            else:
                lm_backend = "vllm"
            logger.info("LLM backend: %s (device: %s)", lm_backend, lm_device)
            # offload_to_cpu=True moves LM off GPU between CoT phases,
            # freeing ~7-16GB of unified memory for the DiT diffusion steps
            status_msg, success = self.llm_handler.initialize(
                checkpoint_dir=self.checkpoint_dir,
                lm_model_path=lm_model_path,
                backend=lm_backend,
                device=lm_device,
                offload_to_cpu=(self.device == "mps"),
            )
            if not success:
                raise GenerationStepError(
                    code="MODEL_INIT_FAILED",
                    step="model load",
                    message=f"Failed to initialize LLM: {status_msg}",
                    fix="Check model files are not corrupted and retry.",
                )
            logger.info("LLM initialized: %s", status_msg)

            self.current_model = model_name
            logger.info("ACE-Step model loaded successfully")
        except GenerationStepError:
            raise
        except ModuleNotFoundError as exc:
            logger.error("Failed to load ACE-Step model: %s", exc)
            raise GenerationStepError(
                code="ACE_STEP_NOT_FOUND",
                step="ACE-Step init",
                message="ACE-Step Python modules could not be imported.",
                fix="Install ACE-Step in Settings, then restart backend.",
                detail=str(exc),
            ) from exc
        except RuntimeError as exc:
            logger.error("Failed to load ACE-Step model: %s", exc)
            text = str(exc).lower()
            if "out of memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="model load",
                    message="Not enough memory to load ACE-Step.",
                    fix="Try a smaller model, shorter duration, or restart backend.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="model load",
                message="Failed while loading ACE-Step model.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Failed to load ACE-Step model: %s", exc)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="model load",
                    message="Disk is full while loading model files.",
                    fix="Free disk space and retry.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="model load",
                message="System error while loading ACE-Step.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Failed to load ACE-Step model: %s", exc)
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="model load",
                message="Unexpected error while loading ACE-Step model.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc

    def _unload_lm_handler(self) -> None:
        """
        Unload ACE-Step LM weights while keeping DiT loaded for subsequent generations.
        """
        with self._model_lock:
            if self.llm_handler is None:
                return

            try:
                logger.info("Unloading ACE-Step LM to free VRAM")
                self.llm_handler = None

                try:
                    import mlx.core as mx
                    if hasattr(mx, "metal") and hasattr(mx.metal, "clear_cache"):
                        mx.metal.clear_cache()
                except Exception:
                    pass

                gc.collect()

                # Clear MPS cache if on Apple Silicon (BUG-004)
                if self._device == "mps":
                    try:
                        _ensure_torch().mps.empty_cache()
                    except Exception:
                        pass
            except Exception as exc:  # noqa: BLE001
                logger.warning("Failed to unload LM: %s", exc)

    def _release_generation_models(self, unload_lm_after_generation: bool) -> None:
        if not unload_lm_after_generation:
            return
        if self.keep_dit_warm:
            self._unload_lm_handler()
            self._schedule_idle_unload()
            return
        self.unload_models()

    def generate_music(
        self,
        caption: str,
        output_path: str,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 150,
        num_inference_steps: int = 8,  # Turbo: 8 steps. Base: 32-100.
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-turbo",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        time_signature: str = "4",
        vocal_language: str = "",
        # ACE-Step v1.5 advanced parameters
        shift: float = 3.0,
        infer_method: str = "ode",
        use_adg: bool = False,
        cfg_interval_start: float = 0.0,
        cfg_interval_end: float = 1.0,
        thinking: bool = True,
        lm_top_k: int = 0,
        lm_top_p: float = 0.9,
        lm_repetition_penalty: float = 1.0,
        lm_negative_prompt: str = "NO USER INPUT",
        constrained_decoding: bool = True,
    ) -> Dict[str, Any]:
        with self._model_lock:
            self._active_generations += 1
            self._cancel_idle_unload()
        self.load_model(model_name=model_name, lm_model_path=lm_model_path)

        try:
            from acestep.inference import GenerationParams, GenerationConfig, generate_music

            logger.info("Generating music: caption='%s...', duration=%ss", caption[:50], duration)
            if progress_callback:
                progress_callback(stage="preparing", percent=10, message="Preparing generation parameters")

            # Set up generation parameters using the ORIGINAL ACE-Step inference API
            # This includes 5Hz LLM Chain-of-Thought reasoning for high-quality results
            params = GenerationParams(
                task_type="text2music",
                caption=caption,
                lyrics=lyrics or "",
                instrumental=(lyrics is None or lyrics.strip() == ""),
                bpm=bpm,
                keyscale=key or "",
                timesignature=time_signature if time_signature else "4",
                vocal_language=vocal_language if vocal_language else "unknown",
                duration=float(duration) if duration else -1.0,
                inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                seed=seed if seed is not None else -1,
                # ACE-Step v1.5 diffusion parameters
                shift=shift,
                infer_method=infer_method,
                use_adg=use_adg,
                cfg_interval_start=cfg_interval_start,
                cfg_interval_end=cfg_interval_end,
                # 5Hz LLM parameters
                thinking=thinking,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                lm_top_k=lm_top_k,
                lm_top_p=lm_top_p,
                # lm_repetition_penalty not supported by ACE-Step GenerationParams
                lm_negative_prompt=lm_negative_prompt,
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=constrained_decoding,
            )

            config = GenerationConfig(
                batch_size=1,
                use_random_seed=(seed is None),
                seeds=[seed] if seed is not None else None,
                audio_format="wav",
            )

            if progress_callback:
                progress_callback(stage="generating", percent=20, message="Loading models...")

            # Generate music (this is the slow part - simulate progress)
            import threading
            import time

            result = None
            generation_complete = False
            generation_error = None

            def run_generation():
                nonlocal result, generation_complete, generation_error
                try:
                    result = generate_music(
                        self.dit_handler,
                        self.llm_handler,
                        params,
                        config,
                        save_dir=str(Path(output_path).parent),
                    )
                except Exception as e:
                    generation_error = e
                finally:
                    generation_complete = True

            # Start generation in background thread
            gen_thread = threading.Thread(target=run_generation, daemon=True)
            gen_thread.start()

            # Simulate progress while generation runs
            progress_milestones = [
                (30, "Analyzing caption..."),
                (40, "Processing musical structure..."),
                (50, "Generating audio..."),
                (60, "Refining composition..."),
                (70, "Finalizing audio..."),
                (80, "Completing generation..."),
            ]

            milestone_index = 0
            while not generation_complete:
                if milestone_index < len(progress_milestones) and progress_callback:
                    percent, message = progress_milestones[milestone_index]
                    progress_callback(stage="generating", percent=percent, message=message)
                    milestone_index += 1
                time.sleep(3)  # Update every 3 seconds

            # Wait for thread to complete
            gen_thread.join()

            if generation_error:
                raise generation_error

            if not result.success:
                raise RuntimeError(f"Generation failed: {result.error}")

            # Get the first generated audio
            audio_info = result.audios[0]
            generated_path = audio_info.get("path", "")
            sample_rate = audio_info.get("sample_rate", 48000)

            # If no path saved (tensor-only result), save it ourselves
            if not generated_path or not Path(generated_path).exists():
                audio_tensor = audio_info.get("tensor")
                if audio_tensor is not None:
                    import soundfile as _sf
                    output_path = str(Path(output_path))
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    data = audio_tensor.cpu()
                    if data.dim() == 2:
                        data = data.t()  # [channel, time] -> [time, channel]
                    if data.dim() == 1:
                        data = data.unsqueeze(-1)
                    data_np = data.numpy()
                    _sf.write(output_path, data_np, sample_rate)
                    # BUG-004: Free tensor/numpy copies immediately after saving
                    del data_np, data, audio_tensor
                    generated_path = output_path
                else:
                    raise RuntimeError("No audio file or tensor in generation result")

            # Move/rename to desired output path if different
            output_path = str(Path(output_path))
            if generated_path != output_path:
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                if Path(generated_path).exists():
                    shutil.copy2(generated_path, output_path)
                else:
                    raise RuntimeError(f"Generated audio not found at {generated_path}")

            logger.info("Saved audio to %s", output_path)
            if progress_callback:
                progress_callback(stage="saved", percent=85, message="Audio saved")

            # Extract metadata
            metadata: Dict[str, Any] = {
                "file_path": output_path,
                "duration": audio_info.get("duration", duration),
                "sample_rate": sample_rate,
                "caption": caption,
                "lyrics": lyrics,
                "seed": audio_info["params"].get("seed", seed),
                "model": model_name,
            }

            # Add BPM and key from generated metadata
            if "params" in audio_info and "bpm" in audio_info["params"]:
                metadata["bpm"] = audio_info["params"]["bpm"]
            elif bpm:
                metadata["bpm"] = bpm

            if "params" in audio_info and "keyscale" in audio_info["params"]:
                metadata["key"] = audio_info["params"]["keyscale"]
            elif key:
                metadata["key"] = key
            else:
                inferred_bpm, inferred_key = _extract_metadata(output_path)
                if metadata.get("bpm") is None:
                    metadata["bpm"] = inferred_bpm
                if metadata.get("key") is None:
                    metadata["key"] = inferred_key

            if progress_callback:
                progress_callback(stage="done", percent=100, message="Generation complete")

            # BUG-004: Dereference the generation result to free any held tensors
            del result, audio_info

            return metadata
        except GenerationStepError:
            raise
        except RuntimeError as exc:
            logger.error("Generation failed: %s", exc, exc_info=True)
            text = str(exc).lower()
            if "out of memory" in text or "mps" in text and "memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="generation",
                    message=(
                        f"Not enough memory during generation "
                        f"(model={model_name}, lm={lm_model_path}, duration={duration}s)."
                    ),
                    fix="Try shorter duration, a smaller LM model (0.6B/1.7B), or close other apps to free RAM.",
                    detail=str(exc),
                ) from exc
            if "checkpoint" in text or "not found" in text or "no such file" in text:
                raise GenerationStepError(
                    code="CHECKPOINT_MISSING",
                    step="generation",
                    message=f"ACE-Step checkpoint not found for model '{model_name}'.",
                    fix="Re-download ACE-Step checkpoints in Settings > Setup, or check that the model name is correct.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message=f"Generation failed: {str(exc)[:200]}",
                fix="Restart backend in Settings and try again. If the error persists, try a different DiT or LM model.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Generation failed: %s", exc, exc_info=True)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="export",
                    message="Disk is full while saving generated audio.",
                    fix="Free disk space and retry export.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="System error during generation.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Generation failed: %s", exc, exc_info=True)
            exc_type = type(exc).__name__
            exc_text = str(exc)[:300]
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message=f"Generation failed ({exc_type}): {exc_text}",
                fix="Restart backend in Settings and try again. If the error persists, try a different model or shorter duration.",
                detail=str(exc),
            ) from exc
        finally:
            with self._model_lock:
                self._active_generations = max(0, self._active_generations - 1)
            self._release_generation_models(unload_lm_after_generation=unload_lm_after_generation)

            # Aggressive cleanup: delete local references to intermediate tensors,
            # then force garbage collection and clear MPS cache.
            # MPS has upstream memory leaks — this won't reclaim ghost memory,
            # but it ensures we don't hold onto anything we can release.
            try:
                # Clear any local tensor references from generation
                for var_name in list(locals().keys()):
                    obj = locals().get(var_name)
                    if hasattr(obj, 'cpu') or hasattr(obj, 'detach'):
                        locals()[var_name] = None
            except Exception:
                pass

            gc.collect()
            self._clear_mlx_cache()
            if self.device == "mps":
                try:
                    _ensure_torch().mps.empty_cache()
                    logger.info("Post-generation MPS cache cleared")
                except Exception as exc:
                    logger.warning("Failed to clear MPS cache: %s", exc)

    def generate_cover(
        self,
        reference_audio: str,
        caption: str,
        output_path: str,
        cover_strength: float = 0.5,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 0,
        num_inference_steps: int = 8,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-turbo",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        time_signature: str = "4",
        vocal_language: str = "",
        # ACE-Step v1.5 advanced parameters
        shift: float = 3.0,
        infer_method: str = "ode",
        use_adg: bool = False,
        cfg_interval_start: float = 0.0,
        cfg_interval_end: float = 1.0,
        thinking: bool = True,
        lm_top_k: int = 0,
        lm_top_p: float = 0.9,
        lm_negative_prompt: str = "NO USER INPUT",
        constrained_decoding: bool = True,
    ) -> Dict[str, Any]:
        """Generate a cover/style transfer from reference audio.

        Uses ACE-Step's task_type="cover" with reference_audio and
        audio_cover_strength to create a new track that blends the
        reference audio's style with the provided caption/lyrics.

        Args:
            reference_audio: Path to the reference audio file.
            caption: Text prompt describing the desired output.
            output_path: Where to save the generated audio.
            cover_strength: 0.0-1.0 — lower = more style transfer,
                            higher = closer to the original reference.
            duration: Target duration in seconds (0 = match reference length).
        """
        if not os.path.exists(reference_audio):
            raise GenerationStepError(
                code="FILE_NOT_FOUND",
                step="cover init",
                message=f"Reference audio not found: {reference_audio}",
                fix="Select a valid audio file and try again.",
            )

        with self._model_lock:
            self._active_generations += 1
            self._cancel_idle_unload()
        self.load_model(model_name=model_name, lm_model_path=lm_model_path)

        try:
            from acestep.inference import GenerationParams, GenerationConfig, generate_music

            # If duration is 0, match the reference audio length
            if duration <= 0:
                ref_duration = librosa.get_duration(path=reference_audio)
                duration = max(10, int(ref_duration))

            logger.info(
                "Generating cover: ref='%s', caption='%s...', strength=%.2f, duration=%ss",
                reference_audio, caption[:50], cover_strength, duration,
            )
            if progress_callback:
                progress_callback(stage="preparing", percent=10, message="Preparing cover generation parameters")

            params = GenerationParams(
                task_type="cover",
                caption=caption,
                lyrics=lyrics or "",
                instrumental=(lyrics is None or lyrics.strip() == ""),
                reference_audio=reference_audio,
                audio_cover_strength=cover_strength,
                bpm=bpm,
                keyscale=key or "",
                timesignature=time_signature if time_signature else "4",
                vocal_language=vocal_language if vocal_language else "unknown",
                duration=float(duration),
                inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                seed=seed if seed is not None else -1,
                # ACE-Step v1.5 diffusion parameters
                shift=shift,
                infer_method=infer_method,
                use_adg=use_adg,
                cfg_interval_start=cfg_interval_start,
                cfg_interval_end=cfg_interval_end,
                # 5Hz LLM parameters
                thinking=thinking,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                lm_top_k=lm_top_k,
                lm_top_p=lm_top_p,
                lm_negative_prompt=lm_negative_prompt,
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=constrained_decoding,
            )

            config = GenerationConfig(
                batch_size=1,
                use_random_seed=(seed is None),
                seeds=[seed] if seed is not None else None,
                audio_format="wav",
            )

            if progress_callback:
                progress_callback(stage="generating", percent=20, message="Loading models for cover generation...")

            # Generate music in background thread with progress simulation
            import time

            result = None
            generation_complete = False
            generation_error = None

            def run_generation():
                nonlocal result, generation_complete, generation_error
                try:
                    result = generate_music(
                        self.dit_handler,
                        self.llm_handler,
                        params,
                        config,
                        save_dir=str(Path(output_path).parent),
                    )
                except Exception as e:
                    generation_error = e
                finally:
                    generation_complete = True

            gen_thread = threading.Thread(target=run_generation, daemon=True)
            gen_thread.start()

            progress_milestones = [
                (30, "Analyzing reference audio..."),
                (40, "Extracting style features..."),
                (50, "Generating cover audio..."),
                (60, "Applying style transfer..."),
                (70, "Refining composition..."),
                (80, "Completing cover generation..."),
            ]

            milestone_index = 0
            while not generation_complete:
                if milestone_index < len(progress_milestones) and progress_callback:
                    percent, message = progress_milestones[milestone_index]
                    progress_callback(stage="generating", percent=percent, message=message)
                    milestone_index += 1
                time.sleep(3)

            gen_thread.join()

            if generation_error:
                raise generation_error

            if not result.success:
                raise RuntimeError(f"Cover generation failed: {result.error}")

            # Get the first generated audio
            audio_info = result.audios[0]
            generated_path = audio_info.get("path", "")
            sample_rate = audio_info.get("sample_rate", 48000)

            # If no path saved (tensor-only result), save it ourselves
            if not generated_path or not Path(generated_path).exists():
                audio_tensor = audio_info.get("tensor")
                if audio_tensor is not None:
                    import soundfile as _sf
                    output_path = str(Path(output_path))
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    data = audio_tensor.cpu()
                    if data.dim() == 2:
                        data = data.t()
                    if data.dim() == 1:
                        data = data.unsqueeze(-1)
                    data_np = data.numpy()
                    _sf.write(output_path, data_np, sample_rate)
                    del data_np, data, audio_tensor
                    generated_path = output_path
                else:
                    raise RuntimeError("No audio file or tensor in cover generation result")

            # Move/rename to desired output path if different
            output_path = str(Path(output_path))
            if generated_path != output_path:
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                if Path(generated_path).exists():
                    shutil.copy2(generated_path, output_path)
                else:
                    raise RuntimeError(f"Generated audio not found at {generated_path}")

            logger.info("Saved cover audio to %s", output_path)
            if progress_callback:
                progress_callback(stage="saved", percent=85, message="Cover audio saved")

            # Extract metadata
            metadata: Dict[str, Any] = {
                "file_path": output_path,
                "duration": audio_info.get("duration", duration),
                "sample_rate": sample_rate,
                "caption": caption,
                "lyrics": lyrics,
                "seed": audio_info["params"].get("seed", seed),
                "model": model_name,
                "task_type": "cover",
                "reference_audio": reference_audio,
                "cover_strength": cover_strength,
            }

            if "params" in audio_info and "bpm" in audio_info["params"]:
                metadata["bpm"] = audio_info["params"]["bpm"]
            elif bpm:
                metadata["bpm"] = bpm

            if "params" in audio_info and "keyscale" in audio_info["params"]:
                metadata["key"] = audio_info["params"]["keyscale"]
            elif key:
                metadata["key"] = key
            else:
                inferred_bpm, inferred_key = _extract_metadata(output_path)
                if metadata.get("bpm") is None:
                    metadata["bpm"] = inferred_bpm
                if metadata.get("key") is None:
                    metadata["key"] = inferred_key

            if progress_callback:
                progress_callback(stage="done", percent=100, message="Cover generation complete")

            del result, audio_info
            return metadata

        except GenerationStepError:
            raise
        except RuntimeError as exc:
            logger.error("Cover generation failed: %s", exc, exc_info=True)
            text = str(exc).lower()
            if "out of memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="generation",
                    message="Not enough memory during cover generation.",
                    fix="Try shorter duration or a smaller model.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Cover generation failed unexpectedly.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Cover generation failed: %s", exc, exc_info=True)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="export",
                    message="Disk is full while saving cover audio.",
                    fix="Free disk space and retry.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="System error during cover generation.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Cover generation failed: %s", exc, exc_info=True)
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Unexpected cover generation failure.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        finally:
            with self._model_lock:
                self._active_generations = max(0, self._active_generations - 1)
            self._release_generation_models(unload_lm_after_generation=unload_lm_after_generation)

            try:
                for var_name in list(locals().keys()):
                    obj = locals().get(var_name)
                    if hasattr(obj, 'cpu') or hasattr(obj, 'detach'):
                        locals()[var_name] = None
            except Exception:
                pass

            gc.collect()
            if self.device == "mps":
                try:
                    _ensure_torch().mps.empty_cache()
                    logger.info("Post-cover-generation MPS cache cleared")
                except Exception as exc:
                    logger.warning("Failed to clear MPS cache: %s", exc)

    def generate_continuation(
        self,
        source_audio: str,
        caption: str,
        output_path: str,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 0,
        num_inference_steps: int = 8,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-turbo",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        time_signature: str = "4",
        vocal_language: str = "",
        # ACE-Step v1.5 advanced parameters
        shift: float = 3.0,
        infer_method: str = "ode",
        use_adg: bool = False,
        cfg_interval_start: float = 0.0,
        cfg_interval_end: float = 1.0,
        thinking: bool = True,
        lm_top_k: int = 0,
        lm_top_p: float = 0.9,
        lm_negative_prompt: str = "NO USER INPUT",
        constrained_decoding: bool = True,
    ) -> Dict[str, Any]:
        """Continue/extend audio from source.

        Uses ACE-Step's task_type="complete" with src_audio to generate
        audio that continues from where the source audio ends.

        Args:
            source_audio: Path to the source audio file to continue from.
            caption: Text prompt describing the desired continuation.
            output_path: Where to save the generated audio.
            duration: Total target duration in seconds (0 = double the source).
        """
        if not os.path.exists(source_audio):
            raise GenerationStepError(
                code="FILE_NOT_FOUND",
                step="continuation init",
                message=f"Source audio not found: {source_audio}",
                fix="Select a valid audio file and try again.",
            )

        with self._model_lock:
            self._active_generations += 1
            self._cancel_idle_unload()
        self.load_model(model_name=model_name, lm_model_path=lm_model_path)

        try:
            from acestep.inference import GenerationParams, GenerationConfig, generate_music

            # If duration is 0, double the source length
            src_duration = librosa.get_duration(path=source_audio)
            if duration <= 0:
                duration = max(30, int(src_duration * 2))

            logger.info(
                "Generating continuation: src='%s' (%.1fs), caption='%s...', target_duration=%ss",
                source_audio, src_duration, caption[:50], duration,
            )
            if progress_callback:
                progress_callback(stage="preparing", percent=10, message="Preparing audio continuation parameters")

            params = GenerationParams(
                task_type="complete",
                caption=caption,
                lyrics=lyrics or "",
                instrumental=(lyrics is None or lyrics.strip() == ""),
                src_audio=source_audio,
                bpm=bpm,
                keyscale=key or "",
                timesignature=time_signature if time_signature else "4",
                vocal_language=vocal_language if vocal_language else "unknown",
                duration=float(duration),
                inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                seed=seed if seed is not None else -1,
                # ACE-Step v1.5 diffusion parameters
                shift=shift,
                infer_method=infer_method,
                use_adg=use_adg,
                cfg_interval_start=cfg_interval_start,
                cfg_interval_end=cfg_interval_end,
                # 5Hz LLM parameters
                thinking=thinking,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                lm_top_k=lm_top_k,
                lm_top_p=lm_top_p,
                lm_negative_prompt=lm_negative_prompt,
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=constrained_decoding,
            )

            config = GenerationConfig(
                batch_size=1,
                use_random_seed=(seed is None),
                seeds=[seed] if seed is not None else None,
                audio_format="wav",
            )

            if progress_callback:
                progress_callback(stage="generating", percent=20, message="Loading models for audio continuation...")

            # Generate music in background thread with progress simulation
            import time

            result = None
            generation_complete = False
            generation_error = None

            def run_generation():
                nonlocal result, generation_complete, generation_error
                try:
                    result = generate_music(
                        self.dit_handler,
                        self.llm_handler,
                        params,
                        config,
                        save_dir=str(Path(output_path).parent),
                    )
                except Exception as e:
                    generation_error = e
                finally:
                    generation_complete = True

            gen_thread = threading.Thread(target=run_generation, daemon=True)
            gen_thread.start()

            progress_milestones = [
                (30, "Analyzing source audio..."),
                (40, "Extracting musical context..."),
                (50, "Generating continuation..."),
                (60, "Extending composition..."),
                (70, "Refining transitions..."),
                (80, "Completing audio continuation..."),
            ]

            milestone_index = 0
            while not generation_complete:
                if milestone_index < len(progress_milestones) and progress_callback:
                    percent, message = progress_milestones[milestone_index]
                    progress_callback(stage="generating", percent=percent, message=message)
                    milestone_index += 1
                time.sleep(3)

            gen_thread.join()

            if generation_error:
                raise generation_error

            if not result.success:
                raise RuntimeError(f"Audio continuation failed: {result.error}")

            # Get the first generated audio
            audio_info = result.audios[0]
            generated_path = audio_info.get("path", "")
            sample_rate = audio_info.get("sample_rate", 48000)

            # If no path saved (tensor-only result), save it ourselves
            if not generated_path or not Path(generated_path).exists():
                audio_tensor = audio_info.get("tensor")
                if audio_tensor is not None:
                    import soundfile as _sf
                    output_path = str(Path(output_path))
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    data = audio_tensor.cpu()
                    if data.dim() == 2:
                        data = data.t()
                    if data.dim() == 1:
                        data = data.unsqueeze(-1)
                    data_np = data.numpy()
                    _sf.write(output_path, data_np, sample_rate)
                    del data_np, data, audio_tensor
                    generated_path = output_path
                else:
                    raise RuntimeError("No audio file or tensor in continuation result")

            # Move/rename to desired output path if different
            output_path = str(Path(output_path))
            if generated_path != output_path:
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                if Path(generated_path).exists():
                    shutil.copy2(generated_path, output_path)
                else:
                    raise RuntimeError(f"Generated audio not found at {generated_path}")

            logger.info("Saved continuation audio to %s", output_path)
            if progress_callback:
                progress_callback(stage="saved", percent=85, message="Continuation audio saved")

            # Extract metadata
            metadata: Dict[str, Any] = {
                "file_path": output_path,
                "duration": audio_info.get("duration", duration),
                "sample_rate": sample_rate,
                "caption": caption,
                "lyrics": lyrics,
                "seed": audio_info["params"].get("seed", seed),
                "model": model_name,
                "task_type": "complete",
                "source_audio": source_audio,
                "source_duration": src_duration,
            }

            if "params" in audio_info and "bpm" in audio_info["params"]:
                metadata["bpm"] = audio_info["params"]["bpm"]
            elif bpm:
                metadata["bpm"] = bpm

            if "params" in audio_info and "keyscale" in audio_info["params"]:
                metadata["key"] = audio_info["params"]["keyscale"]
            elif key:
                metadata["key"] = key
            else:
                inferred_bpm, inferred_key = _extract_metadata(output_path)
                if metadata.get("bpm") is None:
                    metadata["bpm"] = inferred_bpm
                if metadata.get("key") is None:
                    metadata["key"] = inferred_key

            if progress_callback:
                progress_callback(stage="done", percent=100, message="Audio continuation complete")

            del result, audio_info
            return metadata

        except GenerationStepError:
            raise
        except RuntimeError as exc:
            logger.error("Audio continuation failed: %s", exc, exc_info=True)
            text = str(exc).lower()
            if "out of memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="generation",
                    message="Not enough memory during audio continuation.",
                    fix="Try shorter duration or a smaller model.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Audio continuation failed unexpectedly.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Audio continuation failed: %s", exc, exc_info=True)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="export",
                    message="Disk is full while saving continuation audio.",
                    fix="Free disk space and retry.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="System error during audio continuation.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Audio continuation failed: %s", exc, exc_info=True)
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Unexpected audio continuation failure.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        finally:
            with self._model_lock:
                self._active_generations = max(0, self._active_generations - 1)
            self._release_generation_models(unload_lm_after_generation=unload_lm_after_generation)

            try:
                for var_name in list(locals().keys()):
                    obj = locals().get(var_name)
                    if hasattr(obj, 'cpu') or hasattr(obj, 'detach'):
                        locals()[var_name] = None
            except Exception:
                pass

            gc.collect()
            if self.device == "mps":
                try:
                    _ensure_torch().mps.empty_cache()
                    logger.info("Post-continuation MPS cache cleared")
                except Exception as exc:
                    logger.warning("Failed to clear MPS cache: %s", exc)

    def generate_repaint(
        self,
        source_audio: str,
        repainting_start: float,
        repainting_end: float,
        caption: str,
        output_path: str,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 0,
        num_inference_steps: int = 50,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-base",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        time_signature: str = "4",
        vocal_language: str = "",
        # ACE-Step v1.5 advanced parameters
        shift: float = 3.0,
        infer_method: str = "ode",
        use_adg: bool = False,
        cfg_interval_start: float = 0.0,
        cfg_interval_end: float = 1.0,
        thinking: bool = True,
        lm_top_k: int = 0,
        lm_top_p: float = 0.9,
        lm_negative_prompt: str = "NO USER INPUT",
        constrained_decoding: bool = True,
    ) -> Dict[str, Any]:
        """Repaint (regenerate) a specific time range within an existing track.

        Uses ACE-Step's task_type="repaint" to replace a section of audio
        while keeping the rest unchanged.

        Args:
            source_audio: Path to the source audio file.
            repainting_start: Start of the time range to repaint (seconds).
            repainting_end: End of the time range (-1 = end of track).
            caption: Text prompt describing the desired replacement section.
            output_path: Where to save the generated audio.
            duration: Total target duration (0 = match source).
        """
        if not os.path.exists(source_audio):
            raise GenerationStepError(
                code="FILE_NOT_FOUND",
                step="repaint init",
                message=f"Source audio not found: {source_audio}",
                fix="Select a valid audio file and try again.",
            )

        with self._model_lock:
            self._active_generations += 1
            self._cancel_idle_unload()
        self.load_model(model_name=model_name, lm_model_path=lm_model_path)

        try:
            from acestep.inference import GenerationParams, GenerationConfig, generate_music

            # If duration is 0, match the source audio length
            if duration <= 0:
                src_duration = librosa.get_duration(path=source_audio)
                duration = max(10, int(src_duration))

            logger.info(
                "Generating repaint: src='%s', range=%.1f-%.1f, caption='%s...', duration=%ss",
                source_audio, repainting_start, repainting_end, caption[:50], duration,
            )
            if progress_callback:
                progress_callback(stage="preparing", percent=10, message="Preparing repaint parameters")

            params = GenerationParams(
                task_type="repaint",
                caption=caption,
                lyrics=lyrics or "",
                instrumental=(lyrics is None or lyrics.strip() == ""),
                src_audio=source_audio,
                repainting_start=repainting_start,
                repainting_end=repainting_end,
                bpm=bpm,
                keyscale=key or "",
                timesignature=time_signature if time_signature else "4",
                vocal_language=vocal_language if vocal_language else "unknown",
                duration=float(duration),
                inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                seed=seed if seed is not None else -1,
                # ACE-Step v1.5 diffusion parameters
                shift=shift,
                infer_method=infer_method,
                use_adg=use_adg,
                cfg_interval_start=cfg_interval_start,
                cfg_interval_end=cfg_interval_end,
                # 5Hz LLM parameters
                thinking=thinking,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                lm_top_k=lm_top_k,
                lm_top_p=lm_top_p,
                lm_negative_prompt=lm_negative_prompt,
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=constrained_decoding,
            )

            config = GenerationConfig(
                batch_size=1,
                use_random_seed=(seed is None),
                seeds=[seed] if seed is not None else None,
                audio_format="wav",
            )

            if progress_callback:
                progress_callback(stage="generating", percent=20, message="Loading models for repaint...")

            import time

            result = None
            generation_complete = False
            generation_error = None

            def run_generation():
                nonlocal result, generation_complete, generation_error
                try:
                    result = generate_music(
                        self.dit_handler,
                        self.llm_handler,
                        params,
                        config,
                        save_dir=str(Path(output_path).parent),
                    )
                except Exception as e:
                    generation_error = e
                finally:
                    generation_complete = True

            gen_thread = threading.Thread(target=run_generation, daemon=True)
            gen_thread.start()

            progress_milestones = [
                (30, "Analyzing source audio..."),
                (40, "Identifying repaint region..."),
                (50, "Regenerating audio section..."),
                (60, "Blending with original..."),
                (70, "Refining transitions..."),
                (80, "Completing repaint..."),
            ]

            milestone_index = 0
            while not generation_complete:
                if milestone_index < len(progress_milestones) and progress_callback:
                    percent, message = progress_milestones[milestone_index]
                    progress_callback(stage="generating", percent=percent, message=message)
                    milestone_index += 1
                time.sleep(3)

            gen_thread.join()

            if generation_error:
                raise generation_error

            if not result.success:
                raise RuntimeError(f"Repaint generation failed: {result.error}")

            audio_info = result.audios[0]
            generated_path = audio_info.get("path", "")
            sample_rate = audio_info.get("sample_rate", 48000)

            if not generated_path or not Path(generated_path).exists():
                audio_tensor = audio_info.get("tensor")
                if audio_tensor is not None:
                    import soundfile as _sf
                    output_path = str(Path(output_path))
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    data = audio_tensor.cpu()
                    if data.dim() == 2:
                        data = data.t()
                    if data.dim() == 1:
                        data = data.unsqueeze(-1)
                    data_np = data.numpy()
                    _sf.write(output_path, data_np, sample_rate)
                    del data_np, data, audio_tensor
                    generated_path = output_path
                else:
                    raise RuntimeError("No audio file or tensor in repaint result")

            output_path = str(Path(output_path))
            if generated_path != output_path:
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                if Path(generated_path).exists():
                    shutil.copy2(generated_path, output_path)
                else:
                    raise RuntimeError(f"Generated audio not found at {generated_path}")

            logger.info("Saved repaint audio to %s", output_path)
            if progress_callback:
                progress_callback(stage="saved", percent=85, message="Repaint audio saved")

            metadata: Dict[str, Any] = {
                "file_path": output_path,
                "duration": audio_info.get("duration", duration),
                "sample_rate": sample_rate,
                "caption": caption,
                "lyrics": lyrics,
                "seed": audio_info["params"].get("seed", seed),
                "model": model_name,
                "task_type": "repaint",
                "source_audio": source_audio,
                "repainting_start": repainting_start,
                "repainting_end": repainting_end,
            }

            if "params" in audio_info and "bpm" in audio_info["params"]:
                metadata["bpm"] = audio_info["params"]["bpm"]
            elif bpm:
                metadata["bpm"] = bpm

            if "params" in audio_info and "keyscale" in audio_info["params"]:
                metadata["key"] = audio_info["params"]["keyscale"]
            elif key:
                metadata["key"] = key
            else:
                inferred_bpm, inferred_key = _extract_metadata(output_path)
                if metadata.get("bpm") is None:
                    metadata["bpm"] = inferred_bpm
                if metadata.get("key") is None:
                    metadata["key"] = inferred_key

            if progress_callback:
                progress_callback(stage="done", percent=100, message="Repaint complete")

            del result, audio_info
            return metadata

        except GenerationStepError:
            raise
        except RuntimeError as exc:
            logger.error("Repaint failed: %s", exc, exc_info=True)
            text = str(exc).lower()
            if "out of memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="generation",
                    message="Not enough memory during repaint.",
                    fix="Try shorter duration or a smaller model.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Repaint failed unexpectedly.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Repaint failed: %s", exc, exc_info=True)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="export",
                    message="Disk is full while saving repaint audio.",
                    fix="Free disk space and retry.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="System error during repaint.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Repaint failed: %s", exc, exc_info=True)
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Unexpected repaint failure.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        finally:
            with self._model_lock:
                self._active_generations = max(0, self._active_generations - 1)
            self._release_generation_models(unload_lm_after_generation=unload_lm_after_generation)

            try:
                for var_name in list(locals().keys()):
                    obj = locals().get(var_name)
                    if hasattr(obj, 'cpu') or hasattr(obj, 'detach'):
                        locals()[var_name] = None
            except Exception:
                pass

            gc.collect()
            if self.device == "mps":
                try:
                    _ensure_torch().mps.empty_cache()
                    logger.info("Post-repaint MPS cache cleared")
                except Exception as exc:
                    logger.warning("Failed to clear MPS cache: %s", exc)

    def generate_extract(
        self,
        source_audio: str,
        instruction: str,
        caption: str,
        output_path: str,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 0,
        num_inference_steps: int = 50,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-base",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        time_signature: str = "4",
        vocal_language: str = "",
    ) -> Dict[str, Any]:
        """Extract/isolate stems from a mix using ACE-Step.

        Uses ACE-Step's task_type="extract" with an instruction specifying
        which stems to isolate (e.g. "vocals, drums").

        Args:
            source_audio: Path to the source audio file.
            instruction: Comma-separated stems to extract (e.g. "vocals, drums").
            caption: Text prompt (optional context).
            output_path: Where to save the extracted audio.
            duration: Target duration (0 = match source).
        """
        if not os.path.exists(source_audio):
            raise GenerationStepError(
                code="FILE_NOT_FOUND",
                step="extract init",
                message=f"Source audio not found: {source_audio}",
                fix="Select a valid audio file and try again.",
            )

        with self._model_lock:
            self._active_generations += 1
            self._cancel_idle_unload()
        self.load_model(model_name=model_name, lm_model_path=lm_model_path)

        try:
            from acestep.inference import GenerationParams, GenerationConfig, generate_music

            if duration <= 0:
                src_duration = librosa.get_duration(path=source_audio)
                duration = max(10, int(src_duration))

            logger.info(
                "Extracting stems: src='%s', instruction='%s', duration=%ss",
                source_audio, instruction, duration,
            )
            if progress_callback:
                progress_callback(stage="preparing", percent=10, message="Preparing stem extraction parameters")

            params = GenerationParams(
                task_type="extract",
                caption=caption or "",
                lyrics="",
                instrumental=True,
                src_audio=source_audio,
                instruction=instruction,
                bpm=bpm,
                keyscale=key or "",
                timesignature=time_signature if time_signature else "4",
                vocal_language=vocal_language if vocal_language else "unknown",
                duration=float(duration),
                inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                seed=seed if seed is not None else -1,
                thinking=True,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                lm_top_k=0,
                lm_top_p=0.9,
                lm_negative_prompt="NO USER INPUT",
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=True,
            )

            config = GenerationConfig(
                batch_size=1,
                use_random_seed=(seed is None),
                seeds=[seed] if seed is not None else None,
                audio_format="wav",
            )

            if progress_callback:
                progress_callback(stage="generating", percent=20, message="Loading models for stem extraction...")

            import time

            result = None
            generation_complete = False
            generation_error = None

            def run_generation():
                nonlocal result, generation_complete, generation_error
                try:
                    result = generate_music(
                        self.dit_handler,
                        self.llm_handler,
                        params,
                        config,
                        save_dir=str(Path(output_path).parent),
                    )
                except Exception as e:
                    generation_error = e
                finally:
                    generation_complete = True

            gen_thread = threading.Thread(target=run_generation, daemon=True)
            gen_thread.start()

            progress_milestones = [
                (30, "Analyzing source audio..."),
                (40, "Identifying stem components..."),
                (50, "Isolating requested stems..."),
                (60, "Processing extraction..."),
                (70, "Refining separation..."),
                (80, "Completing stem extraction..."),
            ]

            milestone_index = 0
            while not generation_complete:
                if milestone_index < len(progress_milestones) and progress_callback:
                    percent, message = progress_milestones[milestone_index]
                    progress_callback(stage="generating", percent=percent, message=message)
                    milestone_index += 1
                time.sleep(3)

            gen_thread.join()

            if generation_error:
                raise generation_error

            if not result.success:
                raise RuntimeError(f"Stem extraction failed: {result.error}")

            audio_info = result.audios[0]
            generated_path = audio_info.get("path", "")
            sample_rate = audio_info.get("sample_rate", 48000)

            if not generated_path or not Path(generated_path).exists():
                audio_tensor = audio_info.get("tensor")
                if audio_tensor is not None:
                    import soundfile as _sf
                    output_path = str(Path(output_path))
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    data = audio_tensor.cpu()
                    if data.dim() == 2:
                        data = data.t()
                    if data.dim() == 1:
                        data = data.unsqueeze(-1)
                    data_np = data.numpy()
                    _sf.write(output_path, data_np, sample_rate)
                    del data_np, data, audio_tensor
                    generated_path = output_path
                else:
                    raise RuntimeError("No audio file or tensor in extraction result")

            output_path = str(Path(output_path))
            if generated_path != output_path:
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                if Path(generated_path).exists():
                    shutil.copy2(generated_path, output_path)
                else:
                    raise RuntimeError(f"Generated audio not found at {generated_path}")

            logger.info("Saved extracted stems to %s", output_path)
            if progress_callback:
                progress_callback(stage="saved", percent=85, message="Extracted stems saved")

            metadata: Dict[str, Any] = {
                "file_path": output_path,
                "duration": audio_info.get("duration", duration),
                "sample_rate": sample_rate,
                "caption": caption,
                "seed": audio_info["params"].get("seed", seed),
                "model": model_name,
                "task_type": "extract",
                "source_audio": source_audio,
                "instruction": instruction,
            }

            if "params" in audio_info and "bpm" in audio_info["params"]:
                metadata["bpm"] = audio_info["params"]["bpm"]
            elif bpm:
                metadata["bpm"] = bpm

            if "params" in audio_info and "keyscale" in audio_info["params"]:
                metadata["key"] = audio_info["params"]["keyscale"]
            elif key:
                metadata["key"] = key
            else:
                inferred_bpm, inferred_key = _extract_metadata(output_path)
                if metadata.get("bpm") is None:
                    metadata["bpm"] = inferred_bpm
                if metadata.get("key") is None:
                    metadata["key"] = inferred_key

            if progress_callback:
                progress_callback(stage="done", percent=100, message="Stem extraction complete")

            del result, audio_info
            return metadata

        except GenerationStepError:
            raise
        except RuntimeError as exc:
            logger.error("Stem extraction failed: %s", exc, exc_info=True)
            text = str(exc).lower()
            if "out of memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="generation",
                    message="Not enough memory during stem extraction.",
                    fix="Try shorter duration or a smaller model.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Stem extraction failed unexpectedly.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Stem extraction failed: %s", exc, exc_info=True)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="export",
                    message="Disk is full while saving extracted stems.",
                    fix="Free disk space and retry.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="System error during stem extraction.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Stem extraction failed: %s", exc, exc_info=True)
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Unexpected stem extraction failure.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        finally:
            with self._model_lock:
                self._active_generations = max(0, self._active_generations - 1)
            self._release_generation_models(unload_lm_after_generation=unload_lm_after_generation)

            try:
                for var_name in list(locals().keys()):
                    obj = locals().get(var_name)
                    if hasattr(obj, 'cpu') or hasattr(obj, 'detach'):
                        locals()[var_name] = None
            except Exception:
                pass

            gc.collect()
            if self.device == "mps":
                try:
                    _ensure_torch().mps.empty_cache()
                    logger.info("Post-extraction MPS cache cleared")
                except Exception as exc:
                    logger.warning("Failed to clear MPS cache: %s", exc)

    def generate_lego(
        self,
        source_audio: str,
        instruction: str,
        caption: str,
        output_path: str,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 0,
        num_inference_steps: int = 50,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-base",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        time_signature: str = "4",
        vocal_language: str = "",
    ) -> Dict[str, Any]:
        """Generate a new stem/track that fits with existing audio (lego mode).

        Uses ACE-Step's task_type="lego" to create a new instrument layer
        that harmonically and rhythmically fits with the provided context audio.

        Args:
            source_audio: Path to context audio (what the new stem should fit with).
            instruction: What stem to generate (e.g. "bass", "guitar").
            caption: Text prompt describing the desired output.
            output_path: Where to save the generated audio.
            duration: Target duration (0 = match source).
        """
        if source_audio and not os.path.exists(source_audio):
            raise GenerationStepError(
                code="FILE_NOT_FOUND",
                step="lego init",
                message=f"Source audio not found: {source_audio}",
                fix="Select a valid audio file and try again.",
            )

        with self._model_lock:
            self._active_generations += 1
            self._cancel_idle_unload()
        self.load_model(model_name=model_name, lm_model_path=lm_model_path)

        try:
            from acestep.inference import GenerationParams, GenerationConfig, generate_music

            if duration <= 0 and source_audio:
                src_duration = librosa.get_duration(path=source_audio)
                duration = max(10, int(src_duration))
            elif duration <= 0:
                duration = 60  # Default if no source audio

            logger.info(
                "Generating lego stem: src='%s', instruction='%s', caption='%s...', duration=%ss",
                source_audio or "(none)", instruction, caption[:50], duration,
            )
            if progress_callback:
                progress_callback(stage="preparing", percent=10, message="Preparing lego generation parameters")

            params = GenerationParams(
                task_type="lego",
                caption=caption,
                lyrics=lyrics or "",
                instrumental=(lyrics is None or lyrics.strip() == ""),
                src_audio=source_audio or "",
                instruction=instruction,
                bpm=bpm,
                keyscale=key or "",
                timesignature=time_signature if time_signature else "4",
                vocal_language=vocal_language if vocal_language else "unknown",
                duration=float(duration),
                inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                seed=seed if seed is not None else -1,
                thinking=True,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                lm_top_k=0,
                lm_top_p=0.9,
                lm_negative_prompt="NO USER INPUT",
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=True,
            )

            config = GenerationConfig(
                batch_size=1,
                use_random_seed=(seed is None),
                seeds=[seed] if seed is not None else None,
                audio_format="wav",
            )

            if progress_callback:
                progress_callback(stage="generating", percent=20, message="Loading models for lego generation...")

            import time

            result = None
            generation_complete = False
            generation_error = None

            def run_generation():
                nonlocal result, generation_complete, generation_error
                try:
                    result = generate_music(
                        self.dit_handler,
                        self.llm_handler,
                        params,
                        config,
                        save_dir=str(Path(output_path).parent),
                    )
                except Exception as e:
                    generation_error = e
                finally:
                    generation_complete = True

            gen_thread = threading.Thread(target=run_generation, daemon=True)
            gen_thread.start()

            progress_milestones = [
                (30, "Analyzing context audio..."),
                (40, "Understanding musical structure..."),
                (50, "Generating new stem..."),
                (60, "Fitting with context tracks..."),
                (70, "Refining harmonic blend..."),
                (80, "Completing lego generation..."),
            ]

            milestone_index = 0
            while not generation_complete:
                if milestone_index < len(progress_milestones) and progress_callback:
                    percent, message = progress_milestones[milestone_index]
                    progress_callback(stage="generating", percent=percent, message=message)
                    milestone_index += 1
                time.sleep(3)

            gen_thread.join()

            if generation_error:
                raise generation_error

            if not result.success:
                raise RuntimeError(f"Lego generation failed: {result.error}")

            audio_info = result.audios[0]
            generated_path = audio_info.get("path", "")
            sample_rate = audio_info.get("sample_rate", 48000)

            if not generated_path or not Path(generated_path).exists():
                audio_tensor = audio_info.get("tensor")
                if audio_tensor is not None:
                    import soundfile as _sf
                    output_path = str(Path(output_path))
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    data = audio_tensor.cpu()
                    if data.dim() == 2:
                        data = data.t()
                    if data.dim() == 1:
                        data = data.unsqueeze(-1)
                    data_np = data.numpy()
                    _sf.write(output_path, data_np, sample_rate)
                    del data_np, data, audio_tensor
                    generated_path = output_path
                else:
                    raise RuntimeError("No audio file or tensor in lego result")

            output_path = str(Path(output_path))
            if generated_path != output_path:
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                if Path(generated_path).exists():
                    shutil.copy2(generated_path, output_path)
                else:
                    raise RuntimeError(f"Generated audio not found at {generated_path}")

            logger.info("Saved lego stem to %s", output_path)
            if progress_callback:
                progress_callback(stage="saved", percent=85, message="Lego stem saved")

            metadata: Dict[str, Any] = {
                "file_path": output_path,
                "duration": audio_info.get("duration", duration),
                "sample_rate": sample_rate,
                "caption": caption,
                "lyrics": lyrics,
                "seed": audio_info["params"].get("seed", seed),
                "model": model_name,
                "task_type": "lego",
                "source_audio": source_audio,
                "instruction": instruction,
            }

            if "params" in audio_info and "bpm" in audio_info["params"]:
                metadata["bpm"] = audio_info["params"]["bpm"]
            elif bpm:
                metadata["bpm"] = bpm

            if "params" in audio_info and "keyscale" in audio_info["params"]:
                metadata["key"] = audio_info["params"]["keyscale"]
            elif key:
                metadata["key"] = key
            else:
                inferred_bpm, inferred_key = _extract_metadata(output_path)
                if metadata.get("bpm") is None:
                    metadata["bpm"] = inferred_bpm
                if metadata.get("key") is None:
                    metadata["key"] = inferred_key

            if progress_callback:
                progress_callback(stage="done", percent=100, message="Lego generation complete")

            del result, audio_info
            return metadata

        except GenerationStepError:
            raise
        except RuntimeError as exc:
            logger.error("Lego generation failed: %s", exc, exc_info=True)
            text = str(exc).lower()
            if "out of memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="generation",
                    message="Not enough memory during lego generation.",
                    fix="Try shorter duration or a smaller model.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Lego generation failed unexpectedly.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Lego generation failed: %s", exc, exc_info=True)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="export",
                    message="Disk is full while saving lego audio.",
                    fix="Free disk space and retry.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="System error during lego generation.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Lego generation failed: %s", exc, exc_info=True)
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Unexpected lego generation failure.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        finally:
            with self._model_lock:
                self._active_generations = max(0, self._active_generations - 1)
            self._release_generation_models(unload_lm_after_generation=unload_lm_after_generation)

            try:
                for var_name in list(locals().keys()):
                    obj = locals().get(var_name)
                    if hasattr(obj, 'cpu') or hasattr(obj, 'detach'):
                        locals()[var_name] = None
            except Exception:
                pass

            gc.collect()
            if self.device == "mps":
                try:
                    _ensure_torch().mps.empty_cache()
                    logger.info("Post-lego MPS cache cleared")
                except Exception as exc:
                    logger.warning("Failed to clear MPS cache: %s", exc)

    def generate_auto_complete(
        self,
        source_audio: str,
        caption: str,
        output_path: str,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 0,
        num_inference_steps: int = 50,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-base",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        time_signature: str = "4",
        vocal_language: str = "",
    ) -> Dict[str, Any]:
        """Auto-complete a partial mix by filling in missing instruments.

        Uses ACE-Step's task_type="complete" to analyze what instruments
        are present and generate the missing ones to create a full arrangement.

        Args:
            source_audio: Path to the partial mix audio file.
            caption: Text prompt describing desired arrangement.
            output_path: Where to save the generated audio.
            duration: Target duration (0 = match source).
        """
        if not os.path.exists(source_audio):
            raise GenerationStepError(
                code="FILE_NOT_FOUND",
                step="auto_complete init",
                message=f"Source audio not found: {source_audio}",
                fix="Select a valid audio file and try again.",
            )

        with self._model_lock:
            self._active_generations += 1
            self._cancel_idle_unload()
        self.load_model(model_name=model_name, lm_model_path=lm_model_path)

        try:
            from acestep.inference import GenerationParams, GenerationConfig, generate_music

            if duration <= 0:
                src_duration = librosa.get_duration(path=source_audio)
                duration = max(10, int(src_duration))

            logger.info(
                "Generating auto-complete: src='%s', caption='%s...', duration=%ss",
                source_audio, caption[:50], duration,
            )
            if progress_callback:
                progress_callback(stage="preparing", percent=10, message="Preparing auto-complete parameters")

            params = GenerationParams(
                task_type="complete",
                caption=caption,
                lyrics=lyrics or "",
                instrumental=(lyrics is None or lyrics.strip() == ""),
                src_audio=source_audio,
                bpm=bpm,
                keyscale=key or "",
                timesignature=time_signature if time_signature else "4",
                vocal_language=vocal_language if vocal_language else "unknown",
                duration=float(duration),
                inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                seed=seed if seed is not None else -1,
                thinking=True,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                lm_top_k=0,
                lm_top_p=0.9,
                lm_negative_prompt="NO USER INPUT",
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=True,
            )

            config = GenerationConfig(
                batch_size=1,
                use_random_seed=(seed is None),
                seeds=[seed] if seed is not None else None,
                audio_format="wav",
            )

            if progress_callback:
                progress_callback(stage="generating", percent=20, message="Loading models for auto-complete...")

            import time

            result = None
            generation_complete = False
            generation_error = None

            def run_generation():
                nonlocal result, generation_complete, generation_error
                try:
                    result = generate_music(
                        self.dit_handler,
                        self.llm_handler,
                        params,
                        config,
                        save_dir=str(Path(output_path).parent),
                    )
                except Exception as e:
                    generation_error = e
                finally:
                    generation_complete = True

            gen_thread = threading.Thread(target=run_generation, daemon=True)
            gen_thread.start()

            progress_milestones = [
                (30, "Analyzing partial mix..."),
                (40, "Identifying missing instruments..."),
                (50, "Generating arrangement..."),
                (60, "Filling in missing parts..."),
                (70, "Refining full mix..."),
                (80, "Completing auto-arrangement..."),
            ]

            milestone_index = 0
            while not generation_complete:
                if milestone_index < len(progress_milestones) and progress_callback:
                    percent, message = progress_milestones[milestone_index]
                    progress_callback(stage="generating", percent=percent, message=message)
                    milestone_index += 1
                time.sleep(3)

            gen_thread.join()

            if generation_error:
                raise generation_error

            if not result.success:
                raise RuntimeError(f"Auto-complete failed: {result.error}")

            audio_info = result.audios[0]
            generated_path = audio_info.get("path", "")
            sample_rate = audio_info.get("sample_rate", 48000)

            if not generated_path or not Path(generated_path).exists():
                audio_tensor = audio_info.get("tensor")
                if audio_tensor is not None:
                    import soundfile as _sf
                    output_path = str(Path(output_path))
                    Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                    data = audio_tensor.cpu()
                    if data.dim() == 2:
                        data = data.t()
                    if data.dim() == 1:
                        data = data.unsqueeze(-1)
                    data_np = data.numpy()
                    _sf.write(output_path, data_np, sample_rate)
                    del data_np, data, audio_tensor
                    generated_path = output_path
                else:
                    raise RuntimeError("No audio file or tensor in auto-complete result")

            output_path = str(Path(output_path))
            if generated_path != output_path:
                Path(output_path).parent.mkdir(parents=True, exist_ok=True)
                if Path(generated_path).exists():
                    shutil.copy2(generated_path, output_path)
                else:
                    raise RuntimeError(f"Generated audio not found at {generated_path}")

            logger.info("Saved auto-complete audio to %s", output_path)
            if progress_callback:
                progress_callback(stage="saved", percent=85, message="Auto-complete audio saved")

            metadata: Dict[str, Any] = {
                "file_path": output_path,
                "duration": audio_info.get("duration", duration),
                "sample_rate": sample_rate,
                "caption": caption,
                "lyrics": lyrics,
                "seed": audio_info["params"].get("seed", seed),
                "model": model_name,
                "task_type": "complete",
                "source_audio": source_audio,
            }

            if "params" in audio_info and "bpm" in audio_info["params"]:
                metadata["bpm"] = audio_info["params"]["bpm"]
            elif bpm:
                metadata["bpm"] = bpm

            if "params" in audio_info and "keyscale" in audio_info["params"]:
                metadata["key"] = audio_info["params"]["keyscale"]
            elif key:
                metadata["key"] = key
            else:
                inferred_bpm, inferred_key = _extract_metadata(output_path)
                if metadata.get("bpm") is None:
                    metadata["bpm"] = inferred_bpm
                if metadata.get("key") is None:
                    metadata["key"] = inferred_key

            if progress_callback:
                progress_callback(stage="done", percent=100, message="Auto-complete finished")

            del result, audio_info
            return metadata

        except GenerationStepError:
            raise
        except RuntimeError as exc:
            logger.error("Auto-complete failed: %s", exc, exc_info=True)
            text = str(exc).lower()
            if "out of memory" in text:
                raise GenerationStepError(
                    code="OUT_OF_MEMORY",
                    step="generation",
                    message="Not enough memory during auto-complete.",
                    fix="Try shorter duration or a smaller model.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Auto-complete failed unexpectedly.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            logger.error("Auto-complete failed: %s", exc, exc_info=True)
            if exc.errno == errno.ENOSPC:
                raise GenerationStepError(
                    code="DISK_FULL",
                    step="export",
                    message="Disk is full while saving auto-complete audio.",
                    fix="Free disk space and retry.",
                    detail=str(exc),
                ) from exc
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="System error during auto-complete.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        except Exception as exc:  # noqa: BLE001
            logger.error("Auto-complete failed: %s", exc, exc_info=True)
            raise GenerationStepError(
                code="PYTHON_CRASH",
                step="generation",
                message="Unexpected auto-complete failure.",
                fix="Restart backend in Settings and try again.",
                detail=str(exc),
            ) from exc
        finally:
            with self._model_lock:
                self._active_generations = max(0, self._active_generations - 1)
            self._release_generation_models(unload_lm_after_generation=unload_lm_after_generation)

            try:
                for var_name in list(locals().keys()):
                    obj = locals().get(var_name)
                    if hasattr(obj, 'cpu') or hasattr(obj, 'detach'):
                        locals()[var_name] = None
            except Exception:
                pass

            gc.collect()
            if self.device == "mps":
                try:
                    _ensure_torch().mps.empty_cache()
                    logger.info("Post-auto-complete MPS cache cleared")
                except Exception as exc:
                    logger.warning("Failed to clear MPS cache: %s", exc)

    def generate_variants(
        self,
        caption: str,
        output_dir: str,
        count: int,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 150,
        num_inference_steps: int = 8,  # Turbo: 8 steps. Base: 32-100.
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-turbo",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        time_signature: str = "4",
        vocal_language: str = "",
        # ACE-Step v1.5 advanced parameters
        shift: float = 3.0,
        infer_method: str = "ode",
        use_adg: bool = False,
        cfg_interval_start: float = 0.0,
        cfg_interval_end: float = 1.0,
        thinking: bool = True,
        lm_top_k: int = 0,
        lm_top_p: float = 0.9,
        lm_repetition_penalty: float = 1.0,
        lm_negative_prompt: str = "NO USER INPUT",
        constrained_decoding: bool = True,
    ) -> List[Dict[str, Any]]:
        import random
        variants: List[Dict[str, Any]] = []
        count = max(1, min(5, int(count)))
        base_seed = seed if seed is not None else random.randint(0, 1_000_000)

        try:
            for index in range(count):
                variant_seed = base_seed + index
                variant_bpm = bpm
                if bpm is not None:
                    variant_bpm = max(60, min(180, bpm + (index - (count // 2)) * 2))

                variant_key = key
                if key:
                    variant_key = _shift_key(key, index)

                output_path = str(Path(output_dir) / f"variant-{index + 1}.wav")

                def variant_progress(stage: str, percent: int, message: str) -> None:
                    if progress_callback:
                        progress_callback(
                            stage=stage,
                            percent=percent,
                            message=f"Variant {index + 1}/{count}: {message}",
                            variant=index + 1,
                        )

                metadata = self.generate_music(
                    caption=caption,
                    output_path=output_path,
                    lyrics=lyrics,
                    bpm=variant_bpm,
                    key=variant_key,
                    duration=duration,
                    num_inference_steps=num_inference_steps,
                    guidance_scale=guidance_scale,
                    lm_temperature=lm_temperature,
                    lm_cfg_scale=lm_cfg_scale,
                    seed=variant_seed,
                    model_name=model_name,
                    lm_model_path=lm_model_path,
                    progress_callback=variant_progress,
                    unload_lm_after_generation=False,
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
                    # lm_repetition_penalty not supported by ACE-Step GenerationParams
                    lm_negative_prompt=lm_negative_prompt,
                    constrained_decoding=constrained_decoding,
                )
                metadata["variant_index"] = index + 1
                variants.append(metadata)

                # Reclaim intermediate tensors between variants
                gc.collect()
                if self.device == "mps":
                    try:
                        _ensure_torch().mps.empty_cache()
                        logger.info("Inter-variant MPS cache cleared (available RAM: %.1fGB)", _get_available_ram_gb())
                    except Exception as exc:
                        logger.warning("Failed to clear MPS cache between variants: %s", exc)
        finally:
            self._release_generation_models(unload_lm_after_generation=True)

        return variants

    def understand_music(self, audio_path: str, lm_model_path: str = "acestep-5Hz-lm-1.7B") -> Dict[str, Any]:
        """Extract metadata from audio using ACE-Step's music understanding.

        This loads the DiT handler (to convert audio to semantic codes) and the
        LLM handler, then uses the 5Hz Language Model to produce a caption,
        lyrics, BPM, key, duration, language and time signature from the audio.

        If the AI-powered extraction fails (model not installed, OOM, etc.) the
        method falls back to basic librosa-based BPM/key extraction.
        """
        # First, always extract basic metadata via librosa (fast, no model needed)
        basic_bpm, basic_key = _extract_metadata(audio_path)
        try:
            basic_duration = librosa.get_duration(path=audio_path)
        except Exception:
            basic_duration = None

        fallback_result: Dict[str, Any] = {
            "caption": "",
            "lyrics": "",
            "bpm": basic_bpm,
            "key": basic_key,
            "duration": basic_duration,
            "language": "",
            "time_signature": "",
        }

        # Try AI-powered extraction via ACE-Step
        try:
            self.load_model(lm_model_path=lm_model_path)

            # Step 1: Convert audio file to semantic codes using DiT handler
            if self.dit_handler is None:
                logger.warning("DiT handler not available for music understanding; using librosa fallback")
                return fallback_result

            audio_codes = self.dit_handler.convert_src_audio_to_codes(audio_path)
            if not audio_codes or audio_codes.startswith("❌"):
                logger.warning("Audio-to-codes conversion failed: %s; using librosa fallback",
                               audio_codes[:200] if audio_codes else "empty")
                return fallback_result

            # Step 2: Run LLM understanding on the audio codes
            from acestep.inference import understand_music as ace_understand

            result = ace_understand(
                llm_handler=self.llm_handler,
                audio_codes=audio_codes,
            )

            if not result.success:
                logger.warning("AI music understanding failed: %s; using librosa fallback", result.error)
                return fallback_result

            return {
                "caption": result.caption or "",
                "lyrics": result.lyrics or "",
                "bpm": result.bpm if result.bpm is not None else basic_bpm,
                "key": result.keyscale or basic_key or "",
                "duration": result.duration if result.duration is not None else basic_duration,
                "language": result.language or "",
                "time_signature": result.timesignature or "",
            }
        except Exception as exc:
            logger.error("Music understanding failed: %s", exc, exc_info=True)
            return fallback_result
        finally:
            self._release_generation_models(unload_lm_after_generation=True)

    def import_audio(self, source_path: str, output_dir: str) -> Dict[str, Any]:
        source = Path(source_path)
        if not source.exists():
            raise FileNotFoundError(f"Audio file not found: {source_path}")

        output_dir_path = Path(output_dir)
        output_dir_path.mkdir(parents=True, exist_ok=True)

        # Avoid silently overwriting an existing file with the same name
        # (e.g. two imports of different files both called "track.wav").
        target_path = output_dir_path / source.name
        if target_path.exists():
            stem = source.stem
            ext = source.suffix
            n = 2
            while True:
                candidate = output_dir_path / f"{stem}-{n}{ext}"
                if not candidate.exists():
                    target_path = candidate
                    break
                n += 1

        try:
            shutil.copy(source_path, target_path)
        except Exception:
            # Fallback to re-encoding via librosa/soundfile
            y, sr = librosa.load(source_path, sr=None, mono=False)
            if y.ndim == 1:
                y = np.stack([y, y], axis=0)
            sf.write(str(target_path), y.T, sr)
            # BUG-004: Free audio array after writing
            del y

        bpm, key = _extract_metadata(str(target_path))
        duration = librosa.get_duration(path=str(target_path))
        return {
            "file_path": str(target_path),
            "duration": duration,
            "sample_rate": None,
            "bpm": bpm,
            "key": key,
        }

    def _get_ffmpeg_path(self) -> str:
        """Get ffmpeg path - prefer bundled, fall back to system."""
        # Check for bundled version via environment
        bundled = os.getenv("MAJIK_FFMPEG_PATH")
        if bundled and os.path.exists(bundled):
            logger.info("Using bundled ffmpeg from: %s", bundled)
            return bundled

        # Fall back to system ffmpeg
        logger.info("Using system ffmpeg")
        return "ffmpeg"

    def export_track(
        self,
        source_path: str,
        output_path: str,
        format_name: str,
        bitrate: Optional[str] = None,
        progress_callback=None,
    ) -> Dict[str, Any]:
        """
        Export audio file to different formats.

        Args:
            source_path: Input WAV file
            output_path: Output file path
            format_name: wav, flac, mp3, m4a
            bitrate: For lossy formats (e.g., "192k", "320k", "256k")
            progress_callback: Optional callback for progress updates
        """
        source = Path(source_path)
        if not source.exists():
            raise FileNotFoundError(f"Audio file not found: {source_path}")

        output = Path(output_path)
        output.parent.mkdir(parents=True, exist_ok=True)

        format_name = format_name.lower()

        # Lossless formats - use soundfile
        if format_name in {"wav", "flac"}:
            y, sr = librosa.load(source_path, sr=None, mono=False)
            if y.ndim == 1:
                y = np.stack([y, y], axis=0)
            sf.write(str(output), y.T, sr, format=format_name.upper())
            # BUG-004: Free audio array after writing
            del y
            return {"file_path": str(output), "format": format_name}

        # Lossy formats - use ffmpeg for reliability
        if format_name in {"mp3", "m4a"}:
            # Get ffmpeg path (bundled or system)
            ffmpeg_path = self._get_ffmpeg_path()

            # Check ffmpeg availability
            try:
                subprocess.run([ffmpeg_path, "-version"], capture_output=True, check=True)
            except (subprocess.CalledProcessError, FileNotFoundError) as exc:
                raise RuntimeError("ffmpeg not found. Install via: brew install ffmpeg") from exc

            # Default bitrates
            if not bitrate:
                bitrate = "320k" if format_name == "mp3" else "256k"

            # Build ffmpeg command
            cmd = [
                ffmpeg_path,
                "-y",  # Overwrite output
                "-i",
                str(source),
                "-b:a",
                bitrate,
            ]

            if format_name == "m4a":
                cmd.extend(["-c:a", "aac"])  # AAC codec for M4A

            cmd.append(str(output))

            # Run conversion
            if progress_callback:
                progress_callback("exporting", 50, f"Converting to {format_name.upper()}...")

            result = subprocess.run(cmd, capture_output=True, text=True)

            if result.returncode != 0:
                raise RuntimeError(f"FFmpeg error: {result.stderr}")

            if progress_callback:
                progress_callback("done", 100, "Export complete")

            return {"file_path": str(output), "format": format_name, "bitrate": bitrate}

        raise ValueError(f"Unsupported format: {format_name}. Use: wav, flac, mp3, m4a")

    def export_stems(self, source_path: str, output_dir: str) -> Dict[str, Any]:
        source = Path(source_path)
        if not source.exists():
            raise FileNotFoundError(f"Audio file not found: {source_path}")

        output_dir_path = Path(output_dir)
        output_dir_path.mkdir(parents=True, exist_ok=True)

        # Use Demucs CLI for reliable separation.
        # Example: python -m demucs --two-stems vocals -o <out> <file>
        command = [
            sys.executable,
            "-m",
            "demucs",
            "-n",
            "htdemucs",
            "-o",
            str(output_dir_path),
            str(source),
        ]
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode != 0:
            raise RuntimeError(f"Demucs failed: {result.stderr.strip()}")

        # Demucs outputs: <out>/<model>/<track_name>/<stem>.wav
        model_dir = output_dir_path / "htdemucs"
        track_dir = model_dir / source.stem
        if not track_dir.exists():
            raise RuntimeError("Demucs output not found.")

        stems = {
            "vocals": str(track_dir / "vocals.wav"),
            "drums": str(track_dir / "drums.wav"),
            "bass": str(track_dir / "bass.wav"),
            "other": str(track_dir / "other.wav"),
        }
        return {"stems": stems, "output_dir": str(track_dir)}

    def list_models(self) -> List[str]:
        models = ["acestep-v15-turbo", "acestep-v15-quality", "acestep-v15-base"]
        try:
            for entry in os.listdir(self.checkpoint_dir):
                if entry.startswith("."):
                    continue
                models.append(entry)
        except Exception:
            pass
        return sorted(set(models))

    def unload_llm(self) -> Dict[str, Any]:
        """
        Unload the LLM handler to free VRAM.
        DiT handler remains loaded for faster subsequent generations.

        Returns:
            Status message with memory info
        """
        with self._model_lock:
            self._cancel_idle_unload()
            if self.llm_handler is None:
                logger.info("LLM handler already unloaded")
                return {"status": "already_unloaded", "message": "LLM was not loaded"}

            try:
                self.llm_handler = None
                gc.collect()

                # Clear MPS cache if on Apple Silicon
                if self._device == "mps":
                    try:
                        _ensure_torch().mps.empty_cache()
                    except Exception:
                        pass

                logger.info("LLM handler unloaded successfully")
                return {"status": "success", "message": "LLM unloaded, DiT remains loaded"}
            except Exception as exc:
                logger.error("Failed to unload LLM: %s", exc)
                return {"status": "error", "message": str(exc)}

    def unload_models(self) -> Dict[str, Any]:
        """
        Unload both DiT and LLM handlers to free all VRAM.

        Returns:
            Status message with memory info
        """
        with self._model_lock:
            self._cancel_idle_unload()
            unloaded = []

            try:
                if self.llm_handler is not None:
                    self.llm_handler = None
                    unloaded.append("LLM")

                if self.dit_handler is not None:
                    self.dit_handler = None
                    unloaded.append("DiT")

                self.current_model = None
                gc.collect()

                # Clear MPS cache if on Apple Silicon
                if self._device == "mps":
                    try:
                        _ensure_torch().mps.empty_cache()
                    except Exception:
                        pass

                message = f"Unloaded: {', '.join(unloaded)}" if unloaded else "No models were loaded"
                logger.info(message)
                return {"status": "success", "message": message}
            except Exception as exc:
                logger.error("Failed to unload models: %s", exc)
                return {"status": "error", "message": str(exc)}

    def reload_llm(self, model_name: str = "acestep-v15-turbo", lm_model_path: str = "acestep-5Hz-lm-1.7B") -> Dict[str, Any]:
        """
        Reload the LLM handler if it was unloaded.
        DiT handler must already be loaded.

        Args:
            model_name: The model to use for LLM reloading
            lm_model_path: The LM model size (0.6B/1.7B/4B)

        Returns:
            Status message
        """
        if self.llm_handler is not None:
            logger.info("LLM handler already loaded")
            return {"status": "already_loaded", "message": "LLM is already loaded"}

        if self.dit_handler is None:
            logger.warning("Cannot reload LLM without DiT handler")
            return {"status": "error", "message": "DiT handler must be loaded first"}

        try:
            # Add ACE-Step to Python path if needed
            if self.project_root not in sys.path:
                sys.path.insert(0, self.project_root)

            from acestep.llm_inference import LLMHandler

            logger.info("Reloading LLM handler with model: %s", lm_model_path)
            self.llm_handler = LLMHandler()
            force_llm_cpu = os.getenv("ACE_STEP_LLM_CPU", "0").lower() in {"1", "true", "yes"}
            lm_device = "cpu" if force_llm_cpu else self.device
            status_msg, success = self.llm_handler.initialize(
                checkpoint_dir=self.checkpoint_dir,
                lm_model_path=lm_model_path,
                backend="vllm",
                device=lm_device,
            )

            if not success:
                raise RuntimeError(f"Failed to reload LLM: {status_msg}")

            logger.info("LLM reloaded: %s", status_msg)
            return {"status": "success", "message": status_msg}
        except Exception as exc:
            logger.error("Failed to reload LLM: %s", exc)
            self.llm_handler = None
            return {"status": "error", "message": str(exc)}

    def list_available_models(self) -> Dict[str, Any]:
        """
        List all available ACE-Step LM models and their installation status.

        Returns:
            Dictionary with model information
        """
        models = {
            "acestep-5Hz-lm-0.6B": {
                "name": "Tiny (0.6B)",
                "size_gb": 1.2,
                "description": "Smallest, fastest, lower quality",
                "download_url": "https://huggingface.co/ACE-Step/acestep-5Hz-lm-0.6B"
            },
            "acestep-5Hz-lm-1.7B": {
                "name": "Base (1.7B)",
                "size_gb": 3.4,
                "description": "Good balance of speed and quality",
                "download_url": "https://huggingface.co/ACE-Step/Ace-Step1.5/tree/main/acestep-5Hz-lm-1.7B"
            },
            "acestep-5Hz-lm-4B": {
                "name": "Large (4B)",
                "size_gb": 8.0,
                "description": "Best quality, slower, more RAM",
                "download_url": "https://huggingface.co/ACE-Step/acestep-5Hz-lm-4B"
            }
        }

        result = {}
        for model_id, info in models.items():
            model_path = os.path.join(self.checkpoint_dir, model_id)
            is_installed = os.path.exists(model_path) and os.path.isdir(model_path)

            result[model_id] = {
                **info,
                "installed": is_installed,
                "path": model_path if is_installed else None
            }

        return result

    def download_model(self, model_id: str, progress_callback=None) -> Dict[str, Any]:
        """
        Download an ACE-Step LM model from Hugging Face.

        Args:
            model_id: Model identifier (e.g., "acestep-5Hz-lm-4B")
            progress_callback: Optional callback for progress updates

        Returns:
            Status dictionary with success/error

        Raises:
            Exception: If download fails
        """
        # Model configurations with correct repository URLs and file lists
        model_configs = {
            "acestep-5Hz-lm-0.6B": {
                "repo": "ACE-Step/acestep-5Hz-lm-0.6B",
                "files": [
                    "config.json",
                    "model.safetensors",  # FIXED: was model-00001-of-00001.safetensors
                    "special_tokens_map.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "added_tokens.json",
                    "merges.txt",
                    "vocab.json",
                    "chat_template.jinja"
                ]
            },
            "acestep-5Hz-lm-1.7B": {
                "repo": "ACE-Step/Ace-Step1.5",
                "subdir": "acestep-5Hz-lm-1.7B",  # Files are in subdirectory
                "files": [
                    "config.json",
                    "model.safetensors",
                    "special_tokens_map.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "added_tokens.json",
                    "merges.txt",
                    "vocab.json",
                    "chat_template.jinja"
                ]
            },
            "acestep-5Hz-lm-4B": {
                "repo": "ACE-Step/acestep-5Hz-lm-4B",
                "files": [
                    "config.json",
                    "model-00001-of-00002.safetensors",  # FIXED: was 4 shards, actually 2
                    "model-00002-of-00002.safetensors",
                    "model.safetensors.index.json",
                    "special_tokens_map.json",
                    "tokenizer.json",
                    "tokenizer_config.json",
                    "added_tokens.json",
                    "merges.txt",
                    "vocab.json",
                    "chat_template.jinja"
                ]
            }
        }

        if model_id not in model_configs:
            raise ValueError(f"Unknown model: {model_id}")

        model_path = os.path.join(self.checkpoint_dir, model_id)
        if os.path.exists(model_path):
            return {"status": "already_installed", "message": f"{model_id} is already installed"}

        try:
            os.makedirs(model_path, exist_ok=True)
            config = model_configs[model_id]
            repo = config["repo"]
            subdir = config.get("subdir", "")
            files = config["files"]
            total_files = len(files)

            for idx, filename in enumerate(files):
                if progress_callback:
                    progress_callback({
                        "status": "downloading",
                        "file": filename,
                        "progress": int((idx / total_files) * 100),
                        "message": f"Downloading {filename} ({idx + 1}/{total_files})"
                    })

                # Build URL with correct structure
                if subdir:
                    url = f"https://huggingface.co/{repo}/resolve/main/{subdir}/{filename}"
                else:
                    url = f"https://huggingface.co/{repo}/resolve/main/{filename}"

                output_path = os.path.join(model_path, filename)

                logger.info(f"Downloading {filename} from {url}")
                try:
                    # urlretrieve trusts OpenSSL's compiled-in CA file, which is
                    # the Homebrew path. https_urlretrieve uses the bundle's.
                    https_urlretrieve(url, output_path)
                except urllib.error.HTTPError as e:
                    raise Exception(f"Failed to download {filename}: HTTP {e.code} - {e.reason}. Check if model exists at {url}")

            if progress_callback:
                progress_callback({
                    "status": "complete",
                    "progress": 100,
                    "message": f"✅ {model_id} downloaded successfully!"
                })

            logger.info(f"Successfully downloaded {model_id} to {model_path}")
            return {
                "status": "success",
                "message": f"Successfully downloaded {model_id}",
                "path": model_path
            }

        except GenerationStepError:
            logger.error("Failed to download %s", model_id)
            if os.path.exists(model_path):
                shutil.rmtree(model_path, ignore_errors=True)
            raise
        except Exception as e:
            logger.error(f"Failed to download {model_id}: {e}")
            # Clean up partial download
            if os.path.exists(model_path):
                shutil.rmtree(model_path, ignore_errors=True)
            text = str(e)
            lowered = text.lower()
            if "certificate_verify_failed" in lowered or "certificate verify failed" in lowered:
                raise GenerationStepError(
                    code="DOWNLOAD_FAILED",
                    step="language model download",
                    message="Download failed: the app could not verify the server's TLS certificate.",
                    fix="Reinstall Majiks Music Studio. The app ships its own certificate bundle and does not need Homebrew.",
                    detail=text,
                ) from e
            # Raise, rather than return an error dict the wizard would treat as success.
            raise Exception(f"Download failed: {text}") from e


class RemoteACEStepGenerator:
    """Sends generation requests to a remote ACE-Step API server."""

    def __init__(self, server_url: str, api_key: Optional[str] = None):
        self.server_url = server_url.rstrip("/")
        self.api_key = api_key

    def _headers(self) -> Dict[str, str]:
        headers: Dict[str, str] = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        return headers

    def _post_json(self, path: str, body: Dict[str, Any], timeout: int = 30) -> Any:
        import urllib.request
        import urllib.error

        url = f"{self.server_url}{path}"
        data = json.dumps(body).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers=self._headers(), method="POST")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode()[:300] if exc.fp else ""
            raise GenerationStepError(
                code="REMOTE_SERVER_ERROR",
                step="remote request",
                message=f"Remote server returned HTTP {exc.code}: {detail}",
                fix="Check the remote ACE-Step server logs.",
                detail=detail,
            ) from exc
        except urllib.error.URLError as exc:
            raise GenerationStepError(
                code="REMOTE_CONNECTION_FAILED",
                step="remote request",
                message=f"Cannot connect to remote server at {self.server_url}: {exc.reason}",
                fix="Check the server URL and ensure the remote ACE-Step server is running.",
                detail=str(exc.reason),
            ) from exc

    def _get_json(self, path: str, timeout: int = 30) -> Any:
        import urllib.request
        import urllib.error

        url = f"{self.server_url}{path}"
        headers = self._headers()
        headers.pop("Content-Type", None)  # No body for GET
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode()[:300] if exc.fp else ""
            raise GenerationStepError(
                code="REMOTE_SERVER_ERROR",
                step="remote request",
                message=f"Remote server returned HTTP {exc.code}: {detail}",
                fix="Check the remote ACE-Step server logs.",
                detail=detail,
            ) from exc
        except urllib.error.URLError as exc:
            raise GenerationStepError(
                code="REMOTE_CONNECTION_FAILED",
                step="remote request",
                message=f"Cannot connect to remote server: {exc.reason}",
                fix="Check the server URL and ensure the remote ACE-Step server is running.",
                detail=str(exc.reason),
            ) from exc

    def _get(self, path: str, timeout: int = 30) -> bytes:
        import urllib.request
        import urllib.error

        url = f"{self.server_url}{path}"
        headers = self._headers()
        headers.pop("Content-Type", None)
        req = urllib.request.Request(url, headers=headers, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return resp.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode()[:300] if exc.fp else ""
            raise GenerationStepError(
                code="REMOTE_SERVER_ERROR",
                step="remote download",
                message=f"Remote server returned HTTP {exc.code} while downloading audio: {detail}",
                fix="Check the remote ACE-Step server logs.",
                detail=detail,
            ) from exc
        except urllib.error.URLError as exc:
            raise GenerationStepError(
                code="REMOTE_CONNECTION_FAILED",
                step="remote download",
                message=f"Cannot connect to remote server: {exc.reason}",
                fix="Check the server URL and ensure the remote ACE-Step server is running.",
                detail=str(exc.reason),
            ) from exc

    def estimate_memory_requirements(self, **kwargs) -> Dict[str, Any]:
        return {"minimum_gb": 0, "recommended_gb": 0, "expected_peak_gb": "0"}

    def unload_models(self) -> Dict[str, Any]:
        return {"status": "success", "message": "Remote mode — no local models to unload"}

    def unload_llm(self) -> Dict[str, Any]:
        return {"status": "success", "message": "Remote mode — no local LLM to unload"}

    def generate_music(
        self,
        caption: str,
        output_path: str,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 150,
        num_inference_steps: int = 8,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-turbo",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        unload_lm_after_generation: bool = True,
        genre: Optional[str] = None,
        mood: Optional[str] = None,
        artist: Optional[str] = None,
        album: Optional[str] = None,
        time_signature: str = "4",
        vocal_language: str = "",
    ) -> Dict[str, Any]:
        import time
        import urllib.parse

        if progress_callback:
            progress_callback(stage="submitting", percent=5, message="Submitting to remote server...")

        # 1. Submit generation job — server expects {"params": {...}} wrapper
        inner_params: Dict[str, Any] = {
            "tags": caption,
            "lyrics": lyrics or "",
            "instrumental": (lyrics is None or lyrics.strip() == ""),
            "duration": float(duration),
            "num_inference_steps": num_inference_steps,
            "guidance_scale": guidance_scale,
            "lm_temperature": lm_temperature,
            "lm_cfg_scale": lm_cfg_scale,
        }
        if time_signature:
            inner_params["time_signature"] = time_signature
        if vocal_language:
            inner_params["vocal_language"] = vocal_language
        if bpm is not None:
            inner_params["tempo"] = bpm
        if key:
            inner_params["key"] = key
        if seed is not None:
            inner_params["seed"] = seed
        if genre:
            inner_params["genre"] = genre
        if mood:
            inner_params["mood"] = mood
        if artist:
            inner_params["artist"] = artist
        if album:
            inner_params["album"] = album
        # ACE-Step 1.5 server: model selection
        if model_name:
            inner_params["model_id"] = model_name
        if lm_model_path:
            inner_params["lm_model"] = lm_model_path

        task_body: Dict[str, Any] = {"params": inner_params}

        submit_result = self._post_json("/api/v1/studio/generate", task_body, timeout=30)
        # Server returns {"id": "..."} — check `id` first
        task_id = submit_result.get("id") or submit_result.get("job_id") or submit_result.get("task_id")
        if not task_id:
            raise GenerationStepError(
                code="REMOTE_SERVER_ERROR",
                step="submit",
                message="Remote server did not return a job ID.",
                fix="Check the remote ACE-Step server version and logs.",
                detail=str(submit_result),
            )

        logger.info("Remote task submitted: %s", task_id)
        if progress_callback:
            progress_callback(stage="generating", percent=10, message="Task submitted, waiting for generation...")

        # 2. Poll for completion
        poll_timeout = 300 + duration * 180  # Same timeout logic as local
        deadline = time.time() + poll_timeout
        last_percent = 10

        while time.time() < deadline:
            time.sleep(2)

            poll_result = self._get_json(f"/api/v1/studio/jobs/{task_id}", timeout=30)
            status = poll_result.get("status", "").lower()

            if status == "completed" or status == "complete":
                break
            elif status == "failed" or status == "error":
                error_msg = poll_result.get("error") or poll_result.get("message") or "Unknown error"
                raise GenerationStepError(
                    code="REMOTE_GENERATION_FAILED",
                    step="generation",
                    message=f"Remote generation failed: {error_msg}",
                    fix="Check the remote ACE-Step server logs.",
                    detail=str(poll_result),
                )

            # Update progress during polling (10% to 80%)
            if progress_callback:
                elapsed_ratio = min(0.9, (time.time() - (deadline - poll_timeout)) / poll_timeout)
                last_percent = int(10 + elapsed_ratio * 70)
                progress_callback(
                    stage="generating",
                    percent=last_percent,
                    message=f"Generating on remote server ({status})...",
                )
        else:
            raise GenerationStepError(
                code="REMOTE_TIMEOUT",
                step="generation",
                message=f"Remote generation timed out after {poll_timeout}s.",
                fix="Try a shorter duration or check the remote server.",
            )

        if progress_callback:
            progress_callback(stage="downloading", percent=85, message="Downloading audio from remote server...")

        # 3. Download the generated audio
        # Primary: /api/v1/studio/jobs/{id}/audio?variant=0
        # Fallback: audio_url/file_path from poll result
        audio_url = poll_result.get("audio_url") or poll_result.get("file_path")

        try:
            audio_data = self._get(f"/api/v1/studio/jobs/{task_id}/audio?variant=0", timeout=120)
        except Exception as download_err:
            logger.warning("Primary download endpoint failed: %s, trying fallback", download_err)
            audio_data = None

        if not audio_data and audio_url:
            encoded_path = urllib.parse.quote(audio_url, safe="")
            audio_data = self._get(f"/v1/audio?file_path={encoded_path}", timeout=120)

        if not audio_data:
            raise GenerationStepError(
                code="REMOTE_SERVER_ERROR",
                step="download",
                message="Could not download audio from remote server.",
                fix="Check the remote ACE-Step server version.",
                detail=str(poll_result),
            )

        # 4. Save to output_path
        Path(output_path).parent.mkdir(parents=True, exist_ok=True)
        with open(output_path, "wb") as f:
            f.write(audio_data)

        logger.info("Remote audio saved to %s (%d bytes)", output_path, len(audio_data))
        # BUG-004: Free downloaded audio bytes now that they're saved to disk
        del audio_data

        if progress_callback:
            progress_callback(stage="saved", percent=95, message="Audio saved")

        # 5. Extract metadata — prefer server-returned metadata, fall back to librosa
        # Server returns result.variants[].metadata with seed, duration, bpm, generation_time
        server_variants = poll_result.get("result", {}).get("variants", [])
        server_meta = server_variants[0].get("metadata", {}) if server_variants else {}

        actual_duration = server_meta.get("duration", duration)
        sample_rate = 48000
        server_bpm = server_meta.get("bpm")
        generation_time = server_meta.get("generation_time")

        # Fall back to librosa for duration/sample_rate if server didn't provide
        if not server_meta.get("duration"):
            try:
                import librosa
                actual_duration = librosa.get_duration(path=output_path)
                y_sr = librosa.load(output_path, sr=None, mono=True)
                sample_rate = y_sr[1]
                # BUG-004: Free the loaded audio array (only needed sample_rate)
                del y_sr
            except Exception:
                pass

        metadata: Dict[str, Any] = {
            "file_path": output_path,
            "duration": actual_duration,
            "sample_rate": sample_rate,
            "caption": caption,
            "lyrics": lyrics,
            "seed": server_meta.get("seed") or poll_result.get("seed", seed),
            "model": model_name,
            "remote_server": self.server_url,
        }
        if generation_time is not None:
            metadata["generation_time"] = generation_time
        if genre:
            metadata["genre"] = genre
        if mood:
            metadata["mood"] = mood
        if artist:
            metadata["artist"] = artist
        if album:
            metadata["album"] = album

        # BPM: server metadata > request param > audio analysis
        metadata["bpm"] = server_bpm or bpm
        if key:
            metadata["key"] = key

        # Fill in BPM/key from audio analysis if still missing
        if metadata.get("bpm") is None or metadata.get("key") is None:
            inferred_bpm, inferred_key = _extract_metadata(output_path)
            if metadata.get("bpm") is None:
                metadata["bpm"] = inferred_bpm
            if metadata.get("key") is None:
                metadata["key"] = inferred_key

        if progress_callback:
            progress_callback(stage="done", percent=100, message="Generation complete")

        return metadata

    def generate_variants(
        self,
        caption: str,
        output_dir: str,
        count: int,
        lyrics: Optional[str] = None,
        bpm: Optional[int] = None,
        key: Optional[str] = None,
        duration: int = 150,
        num_inference_steps: int = 8,
        guidance_scale: float = 4.5,
        lm_temperature: float = 0.9,
        lm_cfg_scale: float = 2.5,
        seed: Optional[int] = None,
        model_name: str = "acestep-v15-turbo",
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        progress_callback: Optional[callable] = None,
        genre: Optional[str] = None,
        mood: Optional[str] = None,
        artist: Optional[str] = None,
        album: Optional[str] = None,
        time_signature: str = "4",
        vocal_language: str = "",
    ) -> List[Dict[str, Any]]:
        import random

        variants: List[Dict[str, Any]] = []
        count = max(1, min(5, int(count)))
        base_seed = seed if seed is not None else random.randint(0, 1_000_000)

        for index in range(count):
            variant_seed = base_seed + index
            variant_bpm = bpm
            if bpm is not None:
                variant_bpm = max(60, min(180, bpm + (index - (count // 2)) * 2))

            variant_key = key
            if key:
                variant_key = _shift_key(key, index)

            output_path = str(Path(output_dir) / f"variant-{index + 1}.wav")

            def variant_progress(stage: str, percent: int, message: str, _idx=index) -> None:
                if progress_callback:
                    progress_callback(
                        stage=stage,
                        percent=percent,
                        message=f"Variant {_idx + 1}/{count}: {message}",
                        variant=_idx + 1,
                    )

            metadata = self.generate_music(
                caption=caption,
                output_path=output_path,
                lyrics=lyrics,
                bpm=variant_bpm,
                key=variant_key,
                duration=duration,
                num_inference_steps=num_inference_steps,
                guidance_scale=guidance_scale,
                lm_temperature=lm_temperature,
                lm_cfg_scale=lm_cfg_scale,
                seed=variant_seed,
                model_name=model_name,
                lm_model_path=lm_model_path,
                progress_callback=variant_progress,
                genre=genre,
                mood=mood,
                artist=artist,
                album=album,
                time_signature=time_signature,
                vocal_language=vocal_language,
            )
            metadata["variant_index"] = index + 1
            variants.append(metadata)

        return variants

    def save_to_library(self, job_id: str, metadata: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
        """Promote a completed remote job to the server's persistent library."""
        body = metadata or {}
        try:
            result = self._post_json(f"/api/v1/studio/jobs/{job_id}/save", body, timeout=30)
            logger.info("Saved job %s to server library", job_id)
            return result
        except Exception as exc:
            logger.warning("Failed to save job %s to server library: %s", job_id, exc)
            return {"error": str(exc)}

    def export_from_server(self, track_id: str) -> Dict[str, Any]:
        """Request the server to export a track."""
        try:
            result = self._post_json(f"/api/v1/studio/tracks/{track_id}/export", {}, timeout=60)
            return result
        except Exception as exc:
            logger.warning("Server export for track %s failed: %s", track_id, exc)
            return {"error": str(exc)}

    def list_available_models(self) -> Dict[str, Any]:
        return {}

    def list_models(self) -> List[str]:
        return ["acestep-v15-turbo"]


_generator: Optional[ACEStepGenerator] = None


def get_generator() -> ACEStepGenerator:
    global _generator
    if _generator is None:
        _generator = ACEStepGenerator()
    return _generator


def _extract_metadata(file_path: str) -> tuple[Optional[float], Optional[str]]:
    try:
        y, sr = librosa.load(file_path, sr=None, mono=True)
    except Exception:
        return None, None

    bpm: Optional[float]
    key: Optional[str]

    try:
        tempo = librosa.beat.tempo(y=y, sr=sr)
        bpm = float(tempo[0]) if tempo is not None and len(tempo) > 0 else None
    except Exception:
        bpm = None

    try:
        chroma = librosa.feature.chroma_stft(y=y, sr=sr)
        # BUG-004: Free full audio array now that we have the chroma features
        del y
        chroma_mean = chroma.mean(axis=1)
        del chroma

        major_profile = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
        minor_profile = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])

        def best_key(profile: np.ndarray) -> int:
            scores = []
            for i in range(12):
                rotated = np.roll(profile, i)
                scores.append(np.corrcoef(chroma_mean, rotated)[0, 1])
            return int(np.argmax(scores))

        major_key = best_key(major_profile)
        minor_key = best_key(minor_profile)
        key_names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

        major_score = np.corrcoef(chroma_mean, np.roll(major_profile, major_key))[0, 1]
        minor_score = np.corrcoef(chroma_mean, np.roll(minor_profile, minor_key))[0, 1]
        if major_score >= minor_score:
            key = f"{key_names[major_key]} major"
        else:
            key = f"{key_names[minor_key]} minor"
    except Exception:
        key = None

    return bpm, key


def _shift_key(key: str, steps: int) -> str:
    key_names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    tokens = key.split()
    if not tokens:
        return key
    root = tokens[0]
    mode = tokens[1] if len(tokens) > 1 else "major"
    if root not in key_names:
        return key
    idx = key_names.index(root)
    new_root = key_names[(idx + steps) % 12]
    return f"{new_root} {mode}"
