"""
Multi-Provider LLM System for Majiks Studio

Supports:
- Local MLX models (Qwen3-30B-A3B, GPT-OSS-20B)
- OpenRouter (multi-model aggregator)
- Direct APIs (Anthropic, OpenAI, DeepSeek, Gemini)

Priority: Local first, cloud fallback (configurable)
"""

import os
import json
import shutil
import socket
import sys
import urllib.request
import urllib.error
from pathlib import Path
from typing import Optional, Dict, List, Any, Tuple
from dataclasses import dataclass
from enum import Enum


class ProviderType(Enum):
    """Available LLM providers"""
    MLX_LOCAL = "mlx_local"
    OPENROUTER = "openrouter"
    ANTHROPIC = "anthropic"
    OPENAI = "openai"
    DEEPSEEK = "deepseek"
    GEMINI = "gemini"
    OLLAMA = "ollama"
    LM_STUDIO = "lm_studio"
    OPENAI_V1 = "openai_v1"


MODEL_CAPABILITIES: Dict[str, Dict[str, Any]] = {
    "mlx-community/Qwen3.5-4B-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "temperature": 0.7,
        "max_tokens": 1800,
        "display_name": "Qwen 3.5 4B",
        "description": "Compact chat + extraction model, same download for both"
    },
    "mlx-community/Qwen3.5-9B-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "temperature": 0.7,
        "max_tokens": 2200,
        "display_name": "Qwen 3.5 9B (Recommended)",
        "description": "Best local chat model — strong reasoning, native tool calling, 6GB"
    },
    "mlx-community/gpt-oss-20b-MXFP4-Q8": {
        "supports_tools": True,
        "uses_harmony_format": True,
        "reasoning_level": "high",
        "display_name": "GPT-OSS-20B (Best Quality)",
        "description": "20B params, detailed responses, excellent reasoning"
    },
    "lmstudio-community/granite-4.0-h-small-MLX-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "temperature": 0.7,
        "max_tokens": 1000,
        "display_name": "Granite 4.0 H-Small (9B Active)",
        "description": "Hybrid MoE, excellent for creative chat & lyrics"
    },
    "mlx-community/granite-4.0-h-micro-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "temperature": 0.65,
        "max_tokens": 1200,
        "display_name": "Granite 4.0 H-Micro (Fastest)",
        "description": "3B hybrid, blazing fast (1.1s), great quality"
    },
    "mlx-community/granite-3.3-8b-instruct-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "reasoning_level": "medium",
        "temperature": 0.6,
        "max_tokens": 4000,
        "display_name": "Granite 3.3 8B",
        "description": "8B params, 128K context, function calling (⚠️ Consider Granite 4.0 instead)"
    },
    "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "reasoning_level": "high",
        "temperature": 0.7,
        "max_tokens": 2600,
        "display_name": "Qwen3 30B A3B (Best Local)",
        "description": "30B MoE (~3B active): Sterling's default — strong general chat, reasoning & tool calling"
    },
    "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "temperature": 0.85,
        "max_tokens": 3500,
        "display_name": "Qwen3-Coder 30B (Code-Focused)",
        "description": "30B params, code-specialized (⚠️ not optimal for general music chat)"
    },
    "mlx-community/GLM-4.7-Flash-4bit": {
        "supports_tools": True,
        "uses_harmony_format": False,
        "reasoning_level": "medium",
        "temperature": 0.9,
        "max_tokens": 2500,
        "display_name": "GLM-4.7 Flash",
        "description": "Multilingual, fast (60-80 tok/s), tool calling, creative"
    }
}

# Chat uses Granite 4.0 H-Micro: fast, reliable, no tokenizer issues with transformers 4.57.x
# Extraction ALWAYS uses The Engineer/Qwen 3.5 4B (configured in model_configs.py)
DEFAULT_PRIMARY_MODEL = "mlx-community/granite-4.0-h-micro-4bit"
DEFAULT_FALLBACK_MODEL = "lmstudio-community/granite-4.0-h-small-MLX-4bit"

MODEL_SIZE_HINT_GB: Dict[str, int] = {
    "mlx-community/gpt-oss-20b-MXFP4-Q8": 25,
    "lmstudio-community/granite-4.0-h-small-MLX-4bit": 9,
    "mlx-community/granite-4.0-h-micro-4bit": 2,
    "mlx-community/granite-3.3-8b-instruct-4bit": 6,
    "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit": 18,
    "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit": 30,
    "mlx-community/Qwen3.5-4B-4bit": 3,
    "mlx-community/Qwen3.5-9B-4bit": 6,
    "mlx-community/GLM-4.7-Flash-4bit": 8,
}


class ModelDownloadError(Exception):
    def __init__(self, code: str, message: str, fix: str, detail: Optional[str] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.fix = fix
        self.detail = detail


def get_model_capabilities(model_name: Optional[str]) -> Dict[str, Any]:
    if not model_name:
        return {}
    return MODEL_CAPABILITIES.get(model_name, {})


def model_supports_tools(model_name: Optional[str], provider_type: ProviderType) -> bool:
    capabilities = get_model_capabilities(model_name)
    if "supports_tools" in capabilities:
        return bool(capabilities["supports_tools"])

    provider_defaults = {
        ProviderType.OPENROUTER: True,
        ProviderType.ANTHROPIC: False,
        ProviderType.OPENAI: False,
        ProviderType.DEEPSEEK: False,
        ProviderType.GEMINI: False,
        ProviderType.MLX_LOCAL: False,
        ProviderType.OLLAMA: False,
        ProviderType.LM_STUDIO: False,
        ProviderType.OPENAI_V1: False
    }
    return provider_defaults.get(provider_type, False)


def model_uses_harmony(model_name: Optional[str]) -> bool:
    capabilities = get_model_capabilities(model_name)
    return bool(capabilities.get("uses_harmony_format", False))


def model_reasoning_level(model_name: Optional[str]) -> Optional[str]:
    capabilities = get_model_capabilities(model_name)
    return capabilities.get("reasoning_level")


def parse_harmony_format(response: str) -> str:
    """Extract 'final' channel from GPT-OSS harmony format (OpenAI Harmony spec)"""
    import re

    # OpenAI Harmony format uses: <|channel|>analysis<|message|>...<|end|> for thinking
    # and <|channel|>final<|message|>...<|end|> for user-facing response

    # Try to extract the 'final' channel
    final_pattern = r'<\|channel\|>final<\|message\|>(.*?)(?:<\|end\|>|$)'
    match = re.search(final_pattern, response, re.DOTALL)

    if match:
        return match.group(1).strip()

    # Fallback: Strip out any visible channel markers (like **thought<|message|>)
    # This handles cases where the model outputs malformed harmony format
    cleaned = re.sub(r'\*\*(thought|analysis)<\|message\|>', '', response)
    cleaned = re.sub(r'<\|channel\|>(thought|analysis)<\|message\|>.*?<\|end\|>', '', cleaned, flags=re.DOTALL)

    return cleaned.strip() if cleaned.strip() else response.strip()


@dataclass
class LLMConfig:
    """Configuration for LLM providers"""
    # Provider selection
    provider: ProviderType = ProviderType.MLX_LOCAL
    fallback_provider: Optional[ProviderType] = ProviderType.OPENROUTER

    # Local MLX settings
    mlx_model: str = DEFAULT_PRIMARY_MODEL
    mlx_max_tokens: int = 1500
    mlx_temperature: float = 0.75

    # OpenRouter settings
    openrouter_api_key: Optional[str] = None
    openrouter_model: str = "anthropic/claude-3.5-haiku"
    openrouter_max_tokens: int = 600
    openrouter_temperature: float = 0.7

    # Anthropic settings
    anthropic_api_key: Optional[str] = None
    anthropic_model: str = "claude-3-5-haiku-20241022"
    anthropic_max_tokens: int = 600
    anthropic_temperature: float = 0.7

    # OpenAI settings
    openai_api_key: Optional[str] = None
    openai_model: str = "gpt-4o-mini"
    openai_max_tokens: int = 600
    openai_temperature: float = 0.7

    # DeepSeek settings
    deepseek_api_key: Optional[str] = None
    deepseek_model: str = "deepseek-chat"
    deepseek_max_tokens: int = 700
    deepseek_temperature: float = 0.7

    # Gemini settings
    gemini_api_key: Optional[str] = None
    gemini_model: str = "gemini-2.0-flash-exp"
    gemini_max_tokens: int = 800
    gemini_temperature: float = 0.7

    # OpenAI v1 compatible endpoints (Ollama, LM Studio, custom)
    openai_v1_base_url: str = "http://localhost:11434"
    openai_v1_api_key: Optional[str] = None
    openai_v1_model: str = "default"
    openai_v1_max_tokens: int = 600
    openai_v1_temperature: float = 0.7

    # General settings
    max_tokens: int = 600
    temperature: float = 0.7


class MLXProvider:
    """Local MLX model provider"""

    def __init__(self, model_name: str = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"):
        self.model_name = model_name
        self.model = None
        self.tokenizer = None

    def is_available(self) -> bool:
        """Check if MLX and model are available"""
        try:
            import mlx_lm
            return True
        except ImportError:
            return False

    def _patch_tokenizer_config(self):
        """Fix transformers v5 TokenizersBackend class for v4.x compatibility.

        Some MLX community quantizations (e.g. Qwen 3.5) were converted with
        transformers v5 which writes tokenizer_class=TokenizersBackend.  That
        class does not exist in transformers 4.57.x.  Replacing it with the
        generic PreTrainedTokenizerFast lets the tokenizer load normally.
        """
        try:
            from huggingface_hub import try_to_load_from_cache
            cached = try_to_load_from_cache(self.model_name, "tokenizer_config.json")
            if cached and isinstance(cached, str):
                import json
                with open(cached, "r") as f:
                    config = json.load(f)
                if config.get("tokenizer_class") == "TokenizersBackend":
                    config["tokenizer_class"] = "PreTrainedTokenizerFast"
                    with open(cached, "w") as f:
                        json.dump(config, f, indent=2, ensure_ascii=False)
                    print(f"[INFO] Patched tokenizer_config.json: TokenizersBackend -> PreTrainedTokenizerFast", file=sys.stderr)
        except Exception as e:
            print(f"[WARNING] Could not check tokenizer config: {e}", file=sys.stderr)

    def _model_size_hint_gb(self) -> int:
        return MODEL_SIZE_HINT_GB.get(self.model_name, 12)

    def _check_disk_space(self, required_gb: Optional[float] = None) -> Dict[str, Any]:
        required = float(required_gb if required_gb is not None else self._model_size_hint_gb())
        usage = shutil.disk_usage(str(Path.home()))
        free_gb = usage.free / (1024 ** 3)
        ok = free_gb >= required
        return {
            "ok": ok,
            "required_gb": required,
            "free_gb": free_gb,
            "message": f"Need {required:.0f}GB free, only {free_gb:.1f}GB available" if not ok else "Enough disk space",
        }

    def _download_model_if_needed(self, progress_callback=None) -> Optional[str]:
        try:
            from huggingface_hub import HfApi, hf_hub_download
        except ImportError:
            return None

        api = HfApi()
        try:
            info = api.model_info(self.model_name)
        except Exception as exc:
            raise ModelDownloadError(
                code="DOWNLOAD_FAILED",
                message="Download failed: No internet connection",
                fix="Connect to the internet and retry model download.",
                detail=str(exc),
            ) from exc

        tracked_files = [
            sibling.rfilename
            for sibling in info.siblings
            if sibling.rfilename.endswith((".safetensors", ".json", ".model", ".txt"))
            or sibling.rfilename.startswith("tokenizer")
        ]

        if not tracked_files:
            return None

        total = len(tracked_files)
        if progress_callback:
            progress_callback("download", 5, f"Preparing model download ({total} files)")

        for idx, filename in enumerate(tracked_files, start=1):
            pct = min(90, int((idx / total) * 90))
            if progress_callback:
                progress_callback("download", pct, f"Downloading {idx}/{total}: {filename}")
            try:
                hf_hub_download(
                    repo_id=self.model_name,
                    filename=filename,
                    resume_download=True,
                )
            except Exception as exc:
                message = str(exc).lower()
                if "no space" in message or "enospc" in message:
                    raise ModelDownloadError(
                        code="DISK_FULL",
                        message="Download failed: Disk is full",
                        fix="Free disk space, then retry download.",
                        detail=str(exc),
                    ) from exc
                raise ModelDownloadError(
                    code="DOWNLOAD_FAILED",
                    message="Download failed: No internet connection",
                    fix="Connect to the internet and retry model download.",
                    detail=str(exc),
                ) from exc

        if progress_callback:
            progress_callback("download", 95, "Finalizing model cache")
        return self.model_name

    def download_only(self, progress_callback=None):
        """Download model files without loading into memory"""
        disk_check = self._check_disk_space()
        if not disk_check["ok"]:
            raise ModelDownloadError(
                code="DISK_FULL",
                message=disk_check["message"],
                fix="Free disk space before downloading this model.",
            )

        try:
            import sys
            print(f"[INFO] Downloading MLX model: {self.model_name}", file=sys.stderr)
            print(f"[INFO] Download may take several minutes...", file=sys.stderr)

            if progress_callback:
                progress_callback("download", 1, f"Starting download of {self.model_name}")

            # Download files to cache (does NOT load into RAM)
            self._download_model_if_needed(progress_callback=progress_callback)

            if progress_callback:
                progress_callback("done", 100, "Download complete")

            print(f"[INFO] Download complete! Model cached.", file=sys.stderr)
            return self.model_name
        except ModelDownloadError:
            raise
        except Exception as exc:
            raise ModelDownloadError(
                code="DOWNLOAD_FAILED",
                message=f"Download failed: {str(exc)}",
                fix="Check internet connection and retry.",
                detail=str(exc),
            ) from exc

    def load_model(self, progress_callback=None, skip_if_api_configured: bool = False):
        """Load MLX model (auto-downloads from Hugging Face if not cached)"""
        if self.model is not None:
            return  # Already loaded

        # Skip local MLX load/download when an API provider is configured and active.
        if skip_if_api_configured:
            has_api = any([
                os.getenv("OPENROUTER_API_KEY"),
                os.getenv("ANTHROPIC_API_KEY"),
                os.getenv("OPENAI_API_KEY"),
            ])
            provider = os.getenv("LLM_PROVIDER", "mlx_local")
            if has_api and provider != "mlx_local":
                print(f"[INFO] Skipping MLX - API configured ({provider})", file=sys.stderr)
                return

        disk_check = self._check_disk_space()
        if not disk_check["ok"]:
            raise ModelDownloadError(
                code="DISK_FULL",
                message=disk_check["message"],
                fix="Free disk space before downloading this model.",
            )

        try:
            from mlx_lm import load
            from .model_configs import get_bundled_model_path

            # Check if model is bundled in app resources first
            bundled_path = get_bundled_model_path(self.model_name)
            if bundled_path:
                print(f"[INFO] Loading bundled MLX model: {self.model_name}", file=sys.stderr)
                print(f"[INFO] Path: {bundled_path}", file=sys.stderr)
                if progress_callback:
                    progress_callback("loading", 96, "Loading bundled model into memory")

                self.model, self.tokenizer = load(bundled_path)

                if progress_callback:
                    progress_callback("done", 100, "Bundled model loaded successfully")
                print(f"[INFO] Bundled model loaded successfully!", file=sys.stderr)
                return

            # Try loading from local HF cache first (no network needed).
            # Only download if the local load fails (model not yet cached).
            print(f"[INFO] Loading MLX model: {self.model_name}", file=sys.stderr)
            if progress_callback:
                progress_callback("loading", 50, f"Loading {self.model_name}")

            # Patch tokenizer_config.json if needed (fixes transformers v5 models on v4.x)
            self._patch_tokenizer_config()

            try:
                # Force offline mode so load() uses cache without hitting network
                _prev_offline = os.environ.get("HF_HUB_OFFLINE")
                os.environ["HF_HUB_OFFLINE"] = "1"
                try:
                    self.model, self.tokenizer = load(self.model_name)
                finally:
                    # Restore previous offline setting
                    if _prev_offline is None:
                        os.environ.pop("HF_HUB_OFFLINE", None)
                    else:
                        os.environ["HF_HUB_OFFLINE"] = _prev_offline
            except Exception as offline_err:
                # Model not cached locally — download it
                print(f"[INFO] Model not in cache, downloading... ({offline_err})", file=sys.stderr)
                if progress_callback:
                    progress_callback("download", 1, f"Downloading {self.model_name}")
                self._download_model_if_needed(progress_callback=progress_callback)
                # Patch again after fresh download
                self._patch_tokenizer_config()
                if progress_callback:
                    progress_callback("loading", 96, "Loading model into memory")
                self.model, self.tokenizer = load(self.model_name)

            if progress_callback:
                progress_callback("done", 100, "Model loaded successfully")
            print(f"[INFO] Model loaded successfully!", file=sys.stderr)
        except ModelDownloadError:
            raise
        except (urllib.error.URLError, socket.gaierror) as exc:
            raise ModelDownloadError(
                code="DOWNLOAD_FAILED",
                message="Download failed: No internet connection",
                fix="Connect to the internet and retry model download.",
                detail=str(exc),
            ) from exc
        except OSError as exc:
            if "no space" in str(exc).lower():
                raise ModelDownloadError(
                    code="DISK_FULL",
                    message="Download failed: Disk is full",
                    fix="Free disk space before downloading this model.",
                    detail=str(exc),
                ) from exc
            raise Exception(
                f"Failed to load MLX model '{self.model_name}': {exc}\n\n"
                f"The model should download automatically from Hugging Face.\n"
                f"If this persists, check your internet connection or run:\n"
                f"  huggingface-cli download {self.model_name}"
            ) from exc
        except Exception as e:
            raise Exception(
                f"Failed to load MLX model '{self.model_name}': {e}\n\n"
                f"The model should download automatically from Hugging Face.\n"
                f"If this persists, check your internet connection or run:\n"
                f"  huggingface-cli download {self.model_name}"
            ) from e

    def unload_model(self):
        """Unload MLX model to free memory"""
        if self.model is None:
            return  # Already unloaded

        try:
            import sys
            # Delete model and tokenizer
            self.model = None
            self.tokenizer = None

            # Clear MLX cache (use new API, fallback to deprecated)
            import mlx.core as mx
            if hasattr(mx, 'clear_cache'):
                mx.clear_cache()
            elif hasattr(mx, 'metal') and hasattr(mx.metal, 'clear_cache'):
                mx.metal.clear_cache()

            import gc
            gc.collect()
            print("[INFO] 🔧 MLX model unloaded and cache cleared", file=sys.stderr)
        except Exception as e:
            # Non-fatal - just log it
            print(f"[WARNING] Error during MLX unload: {e}", file=sys.stderr)

    def chat(
        self,
        messages: List[Dict[str, str]],
        max_tokens: int = 500,
        temperature: float = 0.7,
        top_p: Optional[float] = None,
        tools: Optional[List[Dict]] = None,
        use_chat_template: bool = True,
        on_partial: Optional[Any] = None,
    ) -> str:
        """Generate response using MLX model.

        Args:
            on_partial: Optional callback ``fn(text_so_far: str)`` invoked
                periodically during token generation so the caller can send
                progressive display updates to the frontend.
        """
        import sys
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler

        sys.stderr.write(f"[MLX] chat() model={self.model_name}, temp={temperature}, max_tokens={max_tokens}\n")

        # Ensure model is loaded
        self.load_model()

        # Apply chat template unless caller explicitly requests plain prompt generation.
        if use_chat_template and self.tokenizer.chat_template is not None:
            template_kwargs = {
                "add_generation_prompt": True,
                "tokenize": False,
            }
            # Qwen 3.5 supports tools in chat template (OpenAI format)
            if tools and hasattr(self.tokenizer, 'chat_template') and self.tokenizer.chat_template and 'tools' in self.tokenizer.chat_template:
                template_kwargs["tools"] = tools
            # Suppress thinking tokens for Qwen 3.5
            if hasattr(self.tokenizer, 'chat_template') and self.tokenizer.chat_template and 'enable_thinking' in self.tokenizer.chat_template:
                template_kwargs["enable_thinking"] = False

            prompt = self.tokenizer.apply_chat_template(
                messages,
                **template_kwargs
            )
        else:
            # Plain prompt mode mirrors direct CLI testing behavior for extraction reliability.
            # Special case: NuExtract uses <|input|>...<|output|> format that shouldn't be wrapped
            if len(messages) == 1 and messages[0].get("content", "").strip().startswith("<|input|>"):
                # NuExtract raw prompt - use as-is without role wrapping
                prompt = messages[0]["content"]
            else:
                parts = []
                for msg in messages:
                    role = msg.get("role", "user").upper()
                    content = msg.get("content", "")
                    parts.append(f"{role}:\n{content}")
                prompt = "\n\n".join(parts) + "\n\nASSISTANT:\n"

        sys.stderr.write(f"[MLX] Prompt length: {len(prompt)}, generating (streaming)...\n")

        # Stream tokens using mlx_lm.stream_generate for progressive display
        sampler = make_sampler(temp=temperature, top_p=top_p if top_p else 0.9)
        response_parts: list = []
        token_count = 0
        for chunk in stream_generate(
            self.model,
            self.tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=sampler,
        ):
            response_parts.append(chunk.text)
            token_count += 1
            # Send partial text every 4 tokens to keep UI responsive
            # without flooding the RPC channel
            if on_partial and token_count % 4 == 0:
                on_partial("".join(response_parts))

        response = "".join(response_parts)
        sys.stderr.write(f"[MLX] Response length: {len(response)} ({token_count} tokens)\n")

        # Strip leaked thinking tokens from Qwen 3.5 models
        # Even with enable_thinking=False, quantized models can sometimes
        # emit <think>...</think> blocks.  Remove them so users never see them.
        response = self._strip_thinking_tokens(response)

        # Parse tool calls from response (Qwen 3.5 outputs <tool_call> blocks)
        tool_calls = self._parse_tool_calls(response)
        if tool_calls:
            clean_text = self._strip_tool_calls(response)
            return {"text": clean_text, "tool_calls": tool_calls}
        return response  # plain string when no tool calls (preserves backward compat)

    def _parse_tool_calls(self, response: str) -> list:
        """Parse tool calls from model output.

        Supports:
        - JSON format: <tool_call>{"name": "...", "arguments": {...}}</tool_call>
        - Also handles: <tool_call>\n{"name": ...}\n</tool_call>
        """
        import re
        tool_calls = []

        # Match <tool_call>...</tool_call> blocks
        pattern = r'<tool_call>\s*(.*?)\s*</tool_call>'
        matches = re.findall(pattern, response, re.DOTALL)

        for match in matches:
            try:
                parsed = json.loads(match.strip())
                name = parsed.get("name", "")
                arguments = parsed.get("arguments", {})
                if name:
                    tool_calls.append({"name": name, "input": arguments})
            except json.JSONDecodeError:
                sys.stderr.write(f"[MLX] Failed to parse tool call JSON: {match[:100]}\n")
                continue

        return tool_calls

    def _strip_tool_calls(self, response: str) -> str:
        """Remove <tool_call>...</tool_call> blocks from response text."""
        import re
        cleaned = re.sub(r'<tool_call>\s*.*?\s*</tool_call>', '', response, flags=re.DOTALL)
        return cleaned.strip()

    @staticmethod
    def _strip_thinking_tokens(response: str) -> str:
        """Remove <think>...</think> blocks that Qwen 3.5 may emit despite enable_thinking=False."""
        import re
        cleaned = re.sub(r'<think>.*?</think>', '', response, flags=re.DOTALL)
        # Also handle unclosed <think> at the start (model started thinking then stopped)
        cleaned = re.sub(r'^<think>.*', '', cleaned, flags=re.DOTALL)
        return cleaned.strip()


class OpenRouterProvider:
    """OpenRouter API provider"""

    BASE_URL = "https://openrouter.ai/api/v1/chat/completions"

    def __init__(self, api_key: str, model: str = "anthropic/claude-3.5-haiku"):
        self.api_key = api_key
        self.model = model

    def is_available(self) -> bool:
        """Check if API key is configured"""
        return self.api_key is not None and len(self.api_key) > 0

    def chat(
        self,
        messages: List[Dict[str, str]],
        max_tokens: int = 500,
        temperature: float = 0.7,
        top_p: Optional[float] = None,
        tools: Optional[List[Dict]] = None,
    ) -> Any:
        """Generate response via OpenRouter API with optional tool support"""

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://majiks-music-studio.app",
            "X-Title": "Majiks Music Studio"
        }

        payload = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": max_tokens
        }
        if top_p is not None:
            payload["top_p"] = top_p

        # Add tools if provided (OpenAI format for OpenRouter)
        if tools:
            # Convert Claude format to OpenAI format for OpenRouter
            openai_tools = []
            for tool in tools:
                openai_tools.append({
                    "type": "function",
                    "function": {
                        "name": tool["name"],
                        "description": tool["description"],
                        "parameters": tool["input_schema"]
                    }
                })
            payload["tools"] = openai_tools
            payload["tool_choice"] = "auto"

        request = urllib.request.Request(
            self.BASE_URL,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST"
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.loads(response.read())
                message = result["choices"][0]["message"]

                # Check for tool calls
                if "tool_calls" in message and message["tool_calls"]:
                    return {
                        "text": message.get("content", ""),
                        "tool_calls": [
                            {
                                "name": tc["function"]["name"],
                                "input": json.loads(tc["function"]["arguments"])
                            }
                            for tc in message["tool_calls"]
                        ]
                    }

                return message["content"]
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else "No details"
            raise Exception(f"OpenRouter API error: {e.code} - {error_body}")


class AnthropicProvider:
    """Anthropic Claude API provider"""

    BASE_URL = "https://api.anthropic.com/v1/messages"
    API_VERSION = "2023-06-01"

    def __init__(self, api_key: str, model: str = "claude-3-5-haiku-20241022"):
        self.api_key = api_key
        self.model = model

    def is_available(self) -> bool:
        return self.api_key is not None and len(self.api_key) > 0

    def chat(
        self,
        messages: List[Dict[str, str]],
        max_tokens: int = 500,
        temperature: float = 0.7,
        top_p: Optional[float] = None,
        tools: Optional[List[Dict]] = None,
    ) -> str:
        """Generate response via Anthropic API"""

        # Extract system message if present
        system_message = None
        filtered_messages = []
        for msg in messages:
            if msg["role"] == "system":
                system_message = msg["content"]
            else:
                filtered_messages.append(msg)

        headers = {
            "x-api-key": self.api_key,
            "anthropic-version": self.API_VERSION,
            "content-type": "application/json"
        }

        payload = {
            "model": self.model,
            "messages": filtered_messages,
            "max_tokens": max_tokens,
            "temperature": temperature
        }
        if top_p is not None:
            payload["top_p"] = top_p

        if system_message:
            payload["system"] = system_message

        request = urllib.request.Request(
            self.BASE_URL,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST"
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.loads(response.read())
                return result["content"][0]["text"]
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else "No details"
            raise Exception(f"Anthropic API error: {e.code} - {error_body}")


class OpenAIProvider:
    """OpenAI API provider"""

    BASE_URL = "https://api.openai.com/v1/chat/completions"

    def __init__(self, api_key: str, model: str = "gpt-4o-mini"):
        self.api_key = api_key
        self.model = model

    def is_available(self) -> bool:
        return self.api_key is not None and len(self.api_key) > 0

    def chat(
        self,
        messages: List[Dict[str, str]],
        max_tokens: int = 500,
        temperature: float = 0.7,
        top_p: Optional[float] = None,
        tools: Optional[List[Dict]] = None,
    ) -> str:
        """Generate response via OpenAI API"""

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature
        }
        if top_p is not None:
            payload["top_p"] = top_p

        request = urllib.request.Request(
            self.BASE_URL,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST"
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.loads(response.read())
                return result["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else "No details"
            raise Exception(f"OpenAI API error: {e.code} - {error_body}")


class DeepSeekProvider:
    """DeepSeek API provider"""

    BASE_URL = "https://api.deepseek.com/v1/chat/completions"

    def __init__(self, api_key: str, model: str = "deepseek-chat"):
        self.api_key = api_key
        self.model = model

    def is_available(self) -> bool:
        return self.api_key is not None and len(self.api_key) > 0

    def chat(
        self,
        messages: List[Dict[str, str]],
        max_tokens: int = 500,
        temperature: float = 0.7,
        top_p: Optional[float] = None,
        tools: Optional[List[Dict]] = None,
    ) -> str:
        """Generate response via DeepSeek API"""

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }

        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature
        }
        if top_p is not None:
            payload["top_p"] = top_p

        request = urllib.request.Request(
            self.BASE_URL,
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST"
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.loads(response.read())
                return result["choices"][0]["message"]["content"]
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else "No details"
            raise Exception(f"DeepSeek API error: {e.code} - {error_body}")


class OpenAIV1Provider:
    """Generic OpenAI v1 compatible endpoint (Ollama, LM Studio, custom)"""

    def __init__(self, base_url: str, api_key: Optional[str] = None, model: str = "default"):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key or ""
        self.model = model

    def is_available(self) -> bool:
        return bool(self.base_url)

    def chat(
        self,
        messages: List[Dict[str, str]],
        max_tokens: int = 500,
        temperature: float = 0.7,
        top_p: Optional[float] = None,
        tools: Optional[List[Dict]] = None,
    ) -> Any:
        headers = {
            "Content-Type": "application/json"
        }
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        payload: Dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": temperature
        }
        if top_p is not None:
            payload["top_p"] = top_p

        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"

        request = urllib.request.Request(
            f"{self.base_url}/v1/chat/completions",
            data=json.dumps(payload).encode(),
            headers=headers,
            method="POST"
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.loads(response.read())
                message = result["choices"][0]["message"]
                if "tool_calls" in message and message["tool_calls"]:
                    tool_calls = []
                    for tool_call in message["tool_calls"]:
                        arguments = tool_call.get("function", {}).get("arguments", "{}")
                        try:
                            parsed_args = json.loads(arguments)
                        except json.JSONDecodeError:
                            parsed_args = {"raw": arguments}
                        tool_calls.append({
                            "name": tool_call.get("function", {}).get("name", ""),
                            "input": parsed_args
                        })
                    return {"text": message.get("content", ""), "tool_calls": tool_calls}
                return message.get("content", "")
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else "No details"
            raise Exception(f"OpenAI v1 API error: {e.code} - {error_body}")


class GeminiProvider:
    """Google Gemini API provider"""

    BASE_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

    def __init__(self, api_key: str, model: str = "gemini-2.0-flash-exp"):
        self.api_key = api_key
        self.model = model

    def is_available(self) -> bool:
        return self.api_key is not None and len(self.api_key) > 0

    def chat(
        self,
        messages: List[Dict[str, str]],
        max_tokens: int = 500,
        temperature: float = 0.7,
        top_p: Optional[float] = None,
        tools: Optional[List[Dict]] = None,
    ) -> str:
        """Generate response via Gemini API"""

        # Convert messages to Gemini format
        contents = []
        for msg in messages:
            role = "user" if msg["role"] in ["user", "system"] else "model"
            contents.append({
                "role": role,
                "parts": [{"text": msg["content"]}]
            })

        url = self.BASE_URL.format(model=self.model) + f"?key={self.api_key}"

        payload = {
            "contents": contents,
            "generationConfig": {
                "temperature": temperature,
                "maxOutputTokens": max_tokens
            }
        }
        if top_p is not None:
            payload["generationConfig"]["topP"] = top_p

        request = urllib.request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST"
        )

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.loads(response.read())
                return result["candidates"][0]["content"]["parts"][0]["text"]
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else "No details"
            raise Exception(f"Gemini API error: {e.code} - {error_body}")


class LLMRouter:
    """
    Intelligent LLM router with multi-provider support

    Routing priority:
    1. Try primary provider
    2. Fall back to secondary provider if primary fails
    3. Return error if all providers fail
    """

    def __init__(self, config: LLMConfig):
        self.config = config
        self.providers = {}
        self._initialize_providers()

    def _initialize_providers(self):
        """Initialize all configured providers"""

        # MLX Local
        if self.config.provider == ProviderType.MLX_LOCAL or \
           self.config.fallback_provider == ProviderType.MLX_LOCAL:
            try:
                self.providers[ProviderType.MLX_LOCAL] = MLXProvider(
                    model_name=self.config.mlx_model
                )
            except Exception as e:
                print(f"Warning: Could not initialize MLX provider: {e}", file=sys.stderr)

        # OpenRouter
        if self.config.openrouter_api_key:
            self.providers[ProviderType.OPENROUTER] = OpenRouterProvider(
                api_key=self.config.openrouter_api_key,
                model=self.config.openrouter_model
            )

        # Anthropic
        if self.config.anthropic_api_key:
            self.providers[ProviderType.ANTHROPIC] = AnthropicProvider(
                api_key=self.config.anthropic_api_key,
                model=self.config.anthropic_model
            )

        # OpenAI
        if self.config.openai_api_key:
            self.providers[ProviderType.OPENAI] = OpenAIProvider(
                api_key=self.config.openai_api_key,
                model=self.config.openai_model
            )

        # DeepSeek
        if self.config.deepseek_api_key:
            self.providers[ProviderType.DEEPSEEK] = DeepSeekProvider(
                api_key=self.config.deepseek_api_key,
                model=self.config.deepseek_model
            )

        # Gemini
        if self.config.gemini_api_key:
            self.providers[ProviderType.GEMINI] = GeminiProvider(
                api_key=self.config.gemini_api_key,
                model=self.config.gemini_model
            )

        # OpenAI v1 compatible endpoints
        if self.config.provider in {ProviderType.OLLAMA, ProviderType.LM_STUDIO, ProviderType.OPENAI_V1} or \
           self.config.fallback_provider in {ProviderType.OLLAMA, ProviderType.LM_STUDIO, ProviderType.OPENAI_V1}:
            openai_v1_provider = OpenAIV1Provider(
                base_url=self.config.openai_v1_base_url,
                api_key=self.config.openai_v1_api_key,
                model=self.config.openai_v1_model
            )
            self.providers[ProviderType.OPENAI_V1] = openai_v1_provider
            self.providers[ProviderType.OLLAMA] = openai_v1_provider
            self.providers[ProviderType.LM_STUDIO] = openai_v1_provider

    def chat(
        self,
        messages: List[Dict[str, str]],
        tools: Optional[List[Dict]] = None,
        max_tokens: Optional[int] = None,
        temperature: Optional[float] = None,
        top_p: Optional[float] = None,
        skip_harmony_parsing: bool = False,
        use_chat_template: bool = True,
        on_partial: Optional[Any] = None,
    ) -> Dict[str, Any]:
        """
        Route chat request to best available provider

        Args:
            messages: Conversation messages
            tools: Optional tool definitions for function calling
            skip_harmony_parsing: If True, don't parse harmony format (for structured outputs like JSON)

        Returns:
            {
                "text": "response text",
                "provider": "provider_name",
                "model": "model_name",
                "source": "local" or "cloud",
                "tool_calls": [...] (optional)
            }
        """

        # Track errors from each provider for diagnostics
        provider_errors = []

        # Try primary provider
        provider = self.providers.get(self.config.provider)
        if provider and provider.is_available():
            try:
                resolved_max_tokens, resolved_temperature = self._resolve_generation_settings(
                    self.config.provider,
                    max_tokens,
                    temperature
                )
                tool_payload = tools if self._provider_supports_tools(self.config.provider) else None
                provider_kwargs = {
                    "max_tokens": resolved_max_tokens,
                    "temperature": resolved_temperature,
                    "top_p": top_p,
                    "tools": tool_payload,
                }
                if self.config.provider == ProviderType.MLX_LOCAL:
                    provider_kwargs["use_chat_template"] = use_chat_template
                    if on_partial:
                        provider_kwargs["on_partial"] = on_partial
                response = provider.chat(messages, **provider_kwargs)

                # Handle both string and dict responses
                if isinstance(response, dict):
                    response_text = response.get("text", "")
                    if not skip_harmony_parsing and model_uses_harmony(self._get_model_name(self.config.provider)):
                        response_text = parse_harmony_format(response_text)
                    return {
                        "text": response_text,
                        "provider": self.config.provider.value,
                        "model": self._get_model_name(self.config.provider),
                        "source": "local" if self.config.provider == ProviderType.MLX_LOCAL else "cloud",
                        "tool_calls": response.get("tool_calls", [])
                    }
                else:
                    if not skip_harmony_parsing and model_uses_harmony(self._get_model_name(self.config.provider)):
                        response = parse_harmony_format(response)
                    return {
                        "text": response,
                        "provider": self.config.provider.value,
                        "model": self._get_model_name(self.config.provider),
                        "source": "local" if self.config.provider == ProviderType.MLX_LOCAL else "cloud"
                    }
            except Exception as e:
                print(f"Primary provider ({self.config.provider.value}) failed: {e}", file=sys.stderr)
                provider_errors.append(f"{self.config.provider.value}: {e}")
                # Re-raise ModelDownloadError directly — fallback won't help
                if isinstance(e, ModelDownloadError):
                    raise
                # Continue to fallback

        # Try fallback provider
        if self.config.fallback_provider:
            fallback = self.providers.get(self.config.fallback_provider)
            if fallback and fallback.is_available():
                try:
                    resolved_max_tokens, resolved_temperature = self._resolve_generation_settings(
                        self.config.fallback_provider,
                        max_tokens,
                        temperature
                    )
                    tool_payload = tools if self._provider_supports_tools(self.config.fallback_provider) else None
                    provider_kwargs = {
                        "max_tokens": resolved_max_tokens,
                        "temperature": resolved_temperature,
                        "top_p": top_p,
                        "tools": tool_payload,
                    }
                    if self.config.fallback_provider == ProviderType.MLX_LOCAL:
                        provider_kwargs["use_chat_template"] = use_chat_template
                        if on_partial:
                            provider_kwargs["on_partial"] = on_partial
                    response = fallback.chat(messages, **provider_kwargs)

                    if isinstance(response, dict):
                        response_text = response.get("text", "")
                        if not skip_harmony_parsing and model_uses_harmony(self._get_model_name(self.config.fallback_provider)):
                            response_text = parse_harmony_format(response_text)
                        return {
                            "text": response_text,
                            "provider": self.config.fallback_provider.value,
                            "model": self._get_model_name(self.config.fallback_provider),
                            "source": "local" if self.config.fallback_provider == ProviderType.MLX_LOCAL else "cloud",
                            "tool_calls": response.get("tool_calls", [])
                        }
                    else:
                        if not skip_harmony_parsing and model_uses_harmony(self._get_model_name(self.config.fallback_provider)):
                            response = parse_harmony_format(response)
                        return {
                            "text": response,
                            "provider": self.config.fallback_provider.value,
                            "model": self._get_model_name(self.config.fallback_provider),
                            "source": "local" if self.config.fallback_provider == ProviderType.MLX_LOCAL else "cloud"
                        }
                except Exception as e:
                    print(f"Fallback provider ({self.config.fallback_provider.value}) failed: {e}", file=sys.stderr)
                    provider_errors.append(f"{self.config.fallback_provider.value}: {e}")
                    # Re-raise ModelDownloadError directly
                    if isinstance(e, ModelDownloadError):
                        raise

        # All providers failed — include actual error details instead of generic message
        error_details = "; ".join(provider_errors) if provider_errors else "No providers available"
        raise Exception(f"All LLM providers failed. {error_details}")

    def _get_model_name(self, provider_type: ProviderType) -> str:
        """Get model name for given provider"""
        mapping = {
            ProviderType.MLX_LOCAL: self.config.mlx_model,
            ProviderType.OPENROUTER: self.config.openrouter_model,
            ProviderType.ANTHROPIC: self.config.anthropic_model,
            ProviderType.OPENAI: self.config.openai_model,
            ProviderType.DEEPSEEK: self.config.deepseek_model,
            ProviderType.GEMINI: self.config.gemini_model,
            ProviderType.OLLAMA: self.config.openai_v1_model,
            ProviderType.LM_STUDIO: self.config.openai_v1_model,
            ProviderType.OPENAI_V1: self.config.openai_v1_model
        }
        return mapping.get(provider_type, "unknown")

    def _resolve_generation_settings(
        self,
        provider_type: ProviderType,
        override_max_tokens: Optional[int],
        override_temperature: Optional[float]
    ) -> tuple[int, float]:
        # First check for model-specific settings in MODEL_CAPABILITIES
        model_name = self._get_model_name(provider_type)
        capabilities = get_model_capabilities(model_name)

        # Use model-specific settings if available, otherwise use overrides, then provider defaults
        model_temp = capabilities.get("temperature")
        model_max_tokens = capabilities.get("max_tokens")

        # Priority: explicit override > model-specific > provider default
        if override_max_tokens is not None and override_temperature is not None:
            return override_max_tokens, override_temperature

        provider_defaults = {
            ProviderType.MLX_LOCAL: (self.config.mlx_max_tokens, self.config.mlx_temperature),
            ProviderType.OPENROUTER: (self.config.openrouter_max_tokens, self.config.openrouter_temperature),
            ProviderType.ANTHROPIC: (self.config.anthropic_max_tokens, self.config.anthropic_temperature),
            ProviderType.OPENAI: (self.config.openai_max_tokens, self.config.openai_temperature),
            ProviderType.DEEPSEEK: (self.config.deepseek_max_tokens, self.config.deepseek_temperature),
            ProviderType.GEMINI: (self.config.gemini_max_tokens, self.config.gemini_temperature),
            ProviderType.OLLAMA: (self.config.openai_v1_max_tokens, self.config.openai_v1_temperature),
            ProviderType.LM_STUDIO: (self.config.openai_v1_max_tokens, self.config.openai_v1_temperature),
            ProviderType.OPENAI_V1: (self.config.openai_v1_max_tokens, self.config.openai_v1_temperature)
        }
        default_max_tokens, default_temperature = provider_defaults.get(
            provider_type,
            (self.config.max_tokens, self.config.temperature)
        )

        # Priority: override > model-specific > provider default
        final_max_tokens = override_max_tokens if override_max_tokens is not None else (
            model_max_tokens if model_max_tokens is not None else default_max_tokens
        )
        final_temperature = override_temperature if override_temperature is not None else (
            model_temp if model_temp is not None else default_temperature
        )

        return (final_max_tokens, final_temperature)

    def _provider_supports_tools(self, provider_type: ProviderType) -> bool:
        model_name = self._get_model_name(provider_type)
        return model_supports_tools(model_name, provider_type)

    def list_available_providers(self) -> List[str]:
        """List all available and configured providers"""
        available = []
        for provider_type, provider in self.providers.items():
            if provider.is_available():
                available.append(provider_type.value)
        return available

    def unload_chat_models(self):
        """Unload chat LLM models to free memory for music generation"""
        try:
            # Unload MLX models if present
            if ProviderType.MLX_LOCAL in self.providers:
                mlx_provider = self.providers[ProviderType.MLX_LOCAL]
                if hasattr(mlx_provider, 'unload_model'):
                    mlx_provider.unload_model()

            # Note: Cloud providers don't hold models in memory, so nothing to unload
            return {"status": "success", "message": "Chat models unloaded"}
        except Exception as e:
            return {"status": "error", "message": str(e)}


# Default configuration from environment variables
def get_default_config() -> LLMConfig:
    """Load configuration from environment variables"""

    provider_raw = os.getenv("LLM_PROVIDER", "mlx_local")
    fallback_raw = os.getenv("LLM_FALLBACK_PROVIDER", "")
    provider = ProviderType(provider_raw)
    fallback_provider = ProviderType(fallback_raw) if fallback_raw else None

    primary_endpoint = os.getenv("LLM_ENDPOINT_URL", "").strip()
    primary_api_key = os.getenv("LLM_API_KEY")
    primary_model = os.getenv("LLM_MODEL", "").strip()

    fallback_endpoint = os.getenv("LLM_FALLBACK_ENDPOINT_URL", "").strip()
    fallback_api_key = os.getenv("LLM_FALLBACK_API_KEY")
    fallback_model = os.getenv("LLM_FALLBACK_MODEL", "").strip()

    openai_v1_base_url = primary_endpoint
    openai_v1_api_key = primary_api_key
    openai_v1_model = primary_model or "default"

    if provider not in {ProviderType.OLLAMA, ProviderType.LM_STUDIO, ProviderType.OPENAI_V1} and \
       fallback_provider in {ProviderType.OLLAMA, ProviderType.LM_STUDIO, ProviderType.OPENAI_V1}:
        openai_v1_base_url = fallback_endpoint
        openai_v1_api_key = fallback_api_key
        openai_v1_model = fallback_model or openai_v1_model

    if provider == ProviderType.OLLAMA and not openai_v1_base_url:
        openai_v1_base_url = "http://localhost:11434"
    if provider == ProviderType.LM_STUDIO and not openai_v1_base_url:
        openai_v1_base_url = "http://localhost:1234"
    if provider not in {ProviderType.OLLAMA, ProviderType.LM_STUDIO, ProviderType.OPENAI_V1} and \
       fallback_provider == ProviderType.LM_STUDIO and not openai_v1_base_url:
        openai_v1_base_url = "http://localhost:1234"
    if provider not in {ProviderType.OLLAMA, ProviderType.LM_STUDIO, ProviderType.OPENAI_V1} and \
       fallback_provider == ProviderType.OLLAMA and not openai_v1_base_url:
        openai_v1_base_url = "http://localhost:11434"

    return LLMConfig(
        # Provider selection
        provider=provider,
        fallback_provider=fallback_provider,

        # MLX settings
        mlx_model=os.getenv("MLX_MODEL", DEFAULT_PRIMARY_MODEL),
        mlx_max_tokens=int(os.getenv("MLX_MAX_TOKENS", "1500")),
        mlx_temperature=float(os.getenv("MLX_TEMPERATURE", "0.75")),

        # OpenRouter
        openrouter_api_key=os.getenv("OPENROUTER_API_KEY"),
        openrouter_model=os.getenv("OPENROUTER_MODEL", "anthropic/claude-3.5-haiku"),
        openrouter_max_tokens=int(os.getenv("OPENROUTER_MAX_TOKENS", "600")),
        openrouter_temperature=float(os.getenv("OPENROUTER_TEMPERATURE", "0.7")),

        # Anthropic
        anthropic_api_key=os.getenv("ANTHROPIC_API_KEY"),
        anthropic_model=os.getenv("ANTHROPIC_MODEL", "claude-3-5-haiku-20241022"),
        anthropic_max_tokens=int(os.getenv("ANTHROPIC_MAX_TOKENS", "600")),
        anthropic_temperature=float(os.getenv("ANTHROPIC_TEMPERATURE", "0.7")),

        # OpenAI
        openai_api_key=os.getenv("OPENAI_API_KEY"),
        openai_model=os.getenv("OPENAI_MODEL", "gpt-4o-mini"),
        openai_max_tokens=int(os.getenv("OPENAI_MAX_TOKENS", "600")),
        openai_temperature=float(os.getenv("OPENAI_TEMPERATURE", "0.7")),

        # DeepSeek
        deepseek_api_key=os.getenv("DEEPSEEK_API_KEY"),
        deepseek_model=os.getenv("DEEPSEEK_MODEL", "deepseek-chat"),
        deepseek_max_tokens=int(os.getenv("DEEPSEEK_MAX_TOKENS", "700")),
        deepseek_temperature=float(os.getenv("DEEPSEEK_TEMPERATURE", "0.7")),

        # Gemini
        gemini_api_key=os.getenv("GEMINI_API_KEY"),
        gemini_model=os.getenv("GEMINI_MODEL", "gemini-2.0-flash-exp"),
        gemini_max_tokens=int(os.getenv("GEMINI_MAX_TOKENS", "800")),
        gemini_temperature=float(os.getenv("GEMINI_TEMPERATURE", "0.7")),

        # OpenAI v1 compatible endpoints
        openai_v1_base_url=openai_v1_base_url or "http://localhost:11434",
        openai_v1_api_key=openai_v1_api_key,
        openai_v1_model=openai_v1_model,
        openai_v1_max_tokens=int(os.getenv("OPENAI_V1_MAX_TOKENS", "600")),
        openai_v1_temperature=float(os.getenv("OPENAI_V1_TEMPERATURE", "0.7")),

        # General
        max_tokens=int(os.getenv("LLM_MAX_TOKENS", "600")),
        temperature=float(os.getenv("LLM_TEMPERATURE", "0.7"))
    )
