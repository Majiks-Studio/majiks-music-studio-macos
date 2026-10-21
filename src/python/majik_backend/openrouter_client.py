from __future__ import annotations

import json
import os
import time
import urllib.request
from typing import Any, Dict, List, Optional


class OpenRouterError(RuntimeError):
    pass


def _headers(api_key: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }


def chat_completions(
    messages: List[Dict[str, str]],
    model: Optional[str] = None,
    timeout: int = 30,
) -> Dict[str, Any]:
    api_key = os.getenv("OPENROUTER_API_KEY")
    if not api_key:
        raise OpenRouterError("OPENROUTER_API_KEY is not set")

    base_url = os.getenv("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1")
    model = model or os.getenv("OPENROUTER_MODEL", "qwen/qwen3-30b-a3b")

    payload = {
        "model": model,
        "messages": messages,
        "temperature": 0.7,
    }

    body = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        url=f"{base_url}/chat/completions",
        data=body,
        headers=_headers(api_key),
        method="POST",
    )

    start = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw)
    except Exception as exc:  # noqa: BLE001
        elapsed = time.time() - start
        raise OpenRouterError(f"OpenRouter request failed after {elapsed:.1f}s: {exc}")
