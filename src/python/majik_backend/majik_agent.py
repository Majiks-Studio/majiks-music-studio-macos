from __future__ import annotations

import json
import logging
import os
from typing import Any, Dict, List, Optional

from .llm_providers import (
    LLMRouter,
    get_default_config,
    ProviderType,
    model_supports_tools,
    model_reasoning_level,
    ModelDownloadError,
)
from .majik_tools import format_tools_for_provider, execute_tool, TOOL_DEFINITIONS
from .model_configs import (
    get_model_system_prompt,
    get_model_inference_params,
    is_model_bundled,
    get_bundled_model_path,
)


logger = logging.getLogger("majik.agent")
MAX_HISTORY_MESSAGES = 20  # Last 20 messages (10 exchanges)

PARAMETER_EXTRACTION_PROMPT = """Extract the music parameters from this conversation as JSON now.
IMPORTANT: If the user changed their mind or refined their request during the conversation, use the MOST RECENT version of their preferences. The latest messages take priority over earlier ones.
For duration, BPM, and key: always prefer the value the USER explicitly asked for over any value the AI assistant suggested or assumed. Only use the assistant's value if the user never specified one."""

PARAMETER_EXTRACTION_SYSTEM = """You extract music parameters from conversations. Return ONLY valid JSON."""

SYSTEM_PROMPT_BASE = """You are Sterling, "The Producer" - the friendly AI music producer inside Majik's Music Studio, from Magic Unicorn Unconventional Technology & Stuff Inc. (A separate specialist agent named "The Engineer" handles technical analysis and parameter extraction - do not introduce yourself as The Engineer.)

YOUR ROLE:
You help users create amazing music through natural conversation. You're a professional producer with deep expertise in music production, genres, theory, and songwriting{tools_description}

COMMUNICATION STYLE:
- BE PROACTIVE: When asked to write lyrics, create a song, or make music - DO IT! Don't just discuss it.
- Use first-person ("I'm thinking...", "Let me write...", "Here's what I created...")
- Give complete outputs - if asked for lyrics, write the full verses and chorus
- Only ask clarifying questions if something is genuinely unclear (like duration or genre)
- Default to taking action over asking questions

**CRITICAL - ALWAYS INCLUDE THESE PARAMETERS** when creating or describing music:
- **BPM**: Always state a specific number (e.g., "128 BPM", "95 BPM") - pick one that fits the genre
- **Key**: Always state a specific musical key (e.g., "C minor", "G major", "F# minor")
- **Duration**: Always state a specific duration (e.g., "2 minutes", "90 seconds", "3:30")
- **Lyrics**: If writing a song with vocals, include complete lyrics with verse/chorus structure
These parameters are REQUIRED for music generation - never skip them!

WHAT YOU CAN DO:
- **Write complete song lyrics** (verses, chorus, bridge) for any genre or theme
- **Suggest full musical arrangements** (BPM, key, instrumentation, structure)
- **Craft detailed music descriptions** ready for generation
- **Answer production questions** about mixing, mastering, sound design
- **Recommend specific parameters** for different genres and moods

MUSIC KNOWLEDGE:
- All genres: modern (trap, lo-fi, hyperpop), classic (rock, jazz), electronic (house, techno)
- Songwriting: verse/chorus structure, rhyme schemes, lyrical themes, storytelling
- Production terms: BPM, key, 808s, drops, hooks, reverb, mixing, compression
- Reference technical details AND emotional qualities (vibe, energy, mood)

EXAMPLES:
User: "Write lyrics for a song about space exploration"
You: "I'll write you a cosmic journey! 🚀

**BPM:** 118
**Key:** E minor
**Duration:** 3 minutes

**Verse 1:**
Counting down from ten to zero
Breaking through the atmosphere, no fear though
Stars align like ancient maps
We're explorers, no looking back

**Chorus:**
We're reaching for the infinite
Dancing through the stars, we're limitless
Light years from where we started from
The universe is ours, the journey's just begun

**Verse 2:**
Galaxies spin like records playing
Every planet got a story worth saying
Nebula clouds paint the sky
We're writing history as we fly by

Want me to {generation_hint}"

User: "I need a chill beat for studying"
You: "Let me create that for you! 🎵

**BPM:** 78
**Key:** C minor
**Duration:** 2 minutes

Lo-fi hip hop with:
- Warm Rhodes piano chords
- Soft vinyl crackle texture
- Mellow kick and snare
- Ambient rain sounds in the background

{generation_hint}"

{tools_section}

Remember: BE HELPFUL BY DOING THE WORK! When users ask for something, deliver it completely. 🎵"""

TOOLS_SECTION_AUTO = """**Your Superpowers (Tools):**
You have access to these tools - use them proactively when users want music:

1. **generate_music**: Create music based on descriptions. When a user asks for music, USE THIS TOOL immediately!
   - Takes: caption (detailed description), duration (30-180s), optional BPM/key, count (1-5 variants)
   - Example: User says "Make me a chill lo-fi beat" → You call generate_music with caption="Chill lo-fi hip hop beat with mellow piano, soft drums, vinyl crackle, relaxed vibe"

2. **import_audio**: Import existing audio files for reference or editing

3. **export_track**: Export generated tracks to files (WAV/MP3/FLAC)

4. **list_available_models**: Show what generation models are available

**When to Use Tools:**
- User says "create", "generate", "make me", "I want" → Use generate_music RIGHT AWAY
- Be proactive! Don't just describe what music would sound like - MAKE IT!
- After generating, tell them what you created and ask if they want variants or changes"""

TOOLS_SECTION_MANUAL = """**Generation Mode:**
You're in MANUAL mode. Users have full control over when music gets generated using the "Generate from Chat" button. Your job is to:
- Help refine their ideas through conversation
- Suggest musical parameters (BPM, key, instruments, mood, etc.)
- Answer questions about music production
- Build up a clear picture of what they want to create
- Let them know when their idea sounds ready to generate

DO NOT automatically generate music. Just discuss and refine the concept."""

# Keep backward compatibility
SYSTEM_PROMPT = SYSTEM_PROMPT_BASE

_custom_prompt_cache_raw: Optional[str] = None
_custom_prompt_cache: Dict[str, str] = {}


class MajikAgentError(Exception):
    def __init__(self, code: str, message: str, fix: str, detail: Optional[str] = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.fix = fix
        self.detail = detail


def _classify_agent_exception(exc: Exception) -> MajikAgentError:
    if isinstance(exc, ModelDownloadError):
        return MajikAgentError(
            code=exc.code,
            message=exc.message,
            fix=exc.fix,
            detail=exc.detail,
        )
    text = str(exc).lower()
    if "out of memory" in text:
        return MajikAgentError(
            code="OUT_OF_MEMORY",
            message="Not enough memory for chat model inference.",
            fix="Try a smaller model or restart backend.",
            detail=str(exc),
        )
    if "model" in text and ("not found" in text or "missing" in text):
        return MajikAgentError(
            code="MODEL_NOT_FOUND",
            message="Model not found. Download model in Settings -> LLM.",
            fix="Download the selected model in Settings -> LLM.",
            detail=str(exc),
        )
    if "download" in text or "internet" in text or "connection" in text or "urlerror" in text:
        return MajikAgentError(
            code="DOWNLOAD_FAILED",
            message="Model download failed. The chat model downloads on first use (~2GB).",
            fix="Check your internet connection and try again.",
            detail=str(exc),
        )
    if "disk" in text or "space" in text or "enospc" in text:
        return MajikAgentError(
            code="DISK_FULL",
            message="Not enough disk space to download the chat model.",
            fix="Free up disk space and try again.",
            detail=str(exc),
        )
    if "all llm providers failed" in text:
        return MajikAgentError(
            code="LLM_LOAD_FAILED",
            message="Chat model failed to load.",
            fix="The model downloads on first use (~2GB). Check internet connection and disk space, then restart backend.",
            detail=str(exc),
        )
    return MajikAgentError(
        code="PYTHON_CRASH",
        message="Chat backend error.",
        fix="Restart backend in Settings.",
        detail=str(exc),
    )


def build_messages(
    user_message: str,
    history: Optional[List[Dict[str, str]]] = None,
    allow_auto_generation: bool = False,
    provider_type: Optional[ProviderType] = None,
    model_name: Optional[str] = None,
    custom_system_prompt: Optional[str] = None,
    agent_config: Optional[Dict[str, Any]] = None,
) -> List[Dict[str, str]]:
    if custom_system_prompt and custom_system_prompt.strip():
        system_prompt = custom_system_prompt
    else:
        system_prompt = _select_system_prompt(
            allow_auto_generation,
            provider_type,
            model_name,
            agent_config=agent_config,
        )
    messages: List[Dict[str, str]] = [{"role": "system", "content": system_prompt}]
    if history:
        truncated_history = history[-MAX_HISTORY_MESSAGES:] if len(history) > MAX_HISTORY_MESSAGES else history
        logger.debug("Chat context: %s/%s messages", len(truncated_history), len(history))
        messages.extend(truncated_history)
    messages.append({"role": "user", "content": user_message})
    return _sanitize_messages(messages)


# Initialize LLM router with default config
_llm_router: Optional[LLMRouter] = None
_llm_router_cache: Dict[str, LLMRouter] = {}

def _router_cache_key(config: Any) -> str:
    payload = {
        "provider": config.provider.value,
        "fallback_provider": config.fallback_provider.value if config.fallback_provider else None,
        "mlx_model": config.mlx_model,
        "openrouter_model": config.openrouter_model,
        "anthropic_model": config.anthropic_model,
        "openai_model": config.openai_model,
        "deepseek_model": config.deepseek_model,
        "gemini_model": config.gemini_model,
        "openai_v1_base_url": config.openai_v1_base_url,
        "openai_v1_model": config.openai_v1_model,
    }
    return json.dumps(payload, sort_keys=True)


def _apply_agent_router_config(base_config: Any, agent_config: Optional[Dict[str, Any]]) -> Any:
    if not agent_config or bool(agent_config.get("uses_app_defaults", True)):
        return base_config

    provider_raw = str(agent_config.get("provider") or "").strip()
    if not provider_raw:
        return base_config

    provider = ProviderType(provider_raw)
    model_name = str(agent_config.get("model") or "").strip()
    base_config.provider = provider
    base_config.fallback_provider = None

    if provider == ProviderType.MLX_LOCAL and model_name:
        base_config.mlx_model = model_name
    elif provider == ProviderType.OPENROUTER and model_name:
        base_config.openrouter_model = model_name
    elif provider == ProviderType.ANTHROPIC and model_name:
        base_config.anthropic_model = model_name
    elif provider == ProviderType.OPENAI and model_name:
        base_config.openai_model = model_name
    elif provider == ProviderType.DEEPSEEK and model_name:
        base_config.deepseek_model = model_name
    elif provider == ProviderType.GEMINI and model_name:
        base_config.gemini_model = model_name
    elif provider in {ProviderType.OLLAMA, ProviderType.LM_STUDIO, ProviderType.OPENAI_V1}:
        if model_name:
            base_config.openai_v1_model = model_name
        if provider == ProviderType.OLLAMA and not base_config.openai_v1_base_url:
            base_config.openai_v1_base_url = "http://localhost:11434"
        if provider == ProviderType.LM_STUDIO and not base_config.openai_v1_base_url:
            base_config.openai_v1_base_url = "http://localhost:1234"

    return base_config


def get_llm_router(agent_config: Optional[Dict[str, Any]] = None) -> LLMRouter:
    """Get or create the default chat router or an agent-specific cached router."""
    global _llm_router
    if not agent_config or bool(agent_config.get("uses_app_defaults", True)):
        if _llm_router is None:
            config = get_default_config()
            _llm_router = LLMRouter(config)
        return _llm_router

    config = _apply_agent_router_config(get_default_config(), agent_config)
    cache_key = _router_cache_key(config)
    cached = _llm_router_cache.get(cache_key)
    if cached is None:
        cached = LLMRouter(config)
        _llm_router_cache[cache_key] = cached
    return cached


def _call_llm(router: LLMRouter, messages: List[Dict[str, str]], **kwargs: Any) -> Dict[str, Any]:
    """
    Thin wrapper around router.chat to normalize output shape.
    """
    response = router.chat(messages, **kwargs)
    if isinstance(response, dict):
        return response
    return {"text": str(response)}


def _noop_partial(_text: str) -> None:
    """Default no-op partial callback."""
    pass


def _build_tool_completion_messages(
    original_messages: List[Dict[str, str]],
    first_result: Dict[str, Any],
    tool_results: List[Dict[str, Any]]
) -> List[Dict[str, str]]:
    """
    Build a provider-agnostic follow-up turn so the LLM can summarize tool execution naturally.
    """
    tool_calls = first_result.get("tool_calls", [])
    tool_calls_json = json.dumps(tool_calls, ensure_ascii=False, indent=2, default=str)
    tool_results_json = json.dumps(tool_results, ensure_ascii=False, indent=2, default=str)

    follow_up_messages = list(original_messages)
    follow_up_messages.append({
        "role": "assistant",
        "content": (
            "I decided to call tools to complete the request.\n"
            f"Tool calls:\n{tool_calls_json}"
        ),
    })
    follow_up_messages.append({
        "role": "user",
        "content": (
            "Tool execution finished. Write a natural response for the user that clearly explains what was done, "
            "what was generated, and what they can do next. Be concise and friendly.\n\n"
            f"Tool results:\n{tool_results_json}"
        ),
    })
    return follow_up_messages


def _clear_memory_caches() -> None:
    """Clear MLX and MPS caches and force garbage collection to reclaim memory."""
    import gc
    gc.collect()

    try:
        import mlx.core as mx
        if hasattr(mx, 'clear_cache'):
            mx.clear_cache()
        elif hasattr(mx, 'metal') and hasattr(mx.metal, 'clear_cache'):
            mx.metal.clear_cache()
        logger.info("🧹 MLX cache cleared")
    except Exception as e:
        logger.debug("Could not clear MLX cache: %s", e)

    try:
        import torch
        if torch.backends.mps.is_available():
            torch.mps.empty_cache()
            logger.info("🧹 MPS cache cleared")
    except Exception as e:
        logger.debug("Could not clear MPS cache: %s", e)


def unload_chat_llm() -> Dict[str, Any]:
    """
    Unload chat LLM models and clear caches to free memory.

    This should be called before loading the extraction model to prevent
    memory pressure from having both models loaded simultaneously.

    Returns:
        Status dict with success/error information
    """
    global _llm_router, _llm_router_cache
    routers: List[LLMRouter] = []
    if _llm_router is not None:
        routers.append(_llm_router)
    routers.extend(_llm_router_cache.values())

    if not routers:
        return {"status": "no_models", "message": "No chat models were loaded"}

    results = [router.unload_chat_models() for router in routers]
    _llm_router = None
    _llm_router_cache = {}
    _clear_memory_caches()
    logger.info("🧹 Chat LLM unloaded + caches cleared")
    return {"status": "success", "routers": results}


# Global engineer router for model management
_engineer_router: Optional[LLMRouter] = None


def unload_engineer_llm() -> Dict[str, Any]:
    """
    Unload Engineer extraction model and clear caches to free memory.

    Returns:
        Status dict with success/error information
    """
    global _engineer_router
    if _engineer_router is None:
        return {"status": "no_models", "message": "No engineer model was loaded"}

    try:
        result = _engineer_router.unload_chat_models()
        _engineer_router = None
        _clear_memory_caches()
        logger.info("🧹 Engineer model unloaded + caches cleared")
        return result
    except Exception as e:
        return {"status": "error", "message": str(e)}


def unload_all_llm() -> Dict[str, Any]:
    """
    Unload all LLM models (chat and engineer) and clear all caches.
    Called before ACE-Step generation to maximize available memory.

    Returns:
        Status dict with results from both unloads
    """
    chat_result = unload_chat_llm()
    engineer_result = unload_engineer_llm()
    _clear_memory_caches()  # Final sweep after both unloads

    return {
        "status": "success",
        "chat": chat_result,
        "engineer": engineer_result,
        "message": "All LLM models unloaded, caches cleared"
    }


def reload_chat_llm() -> Dict[str, Any]:
    """
    Reload the chat LLM after it was unloaded (e.g., for music generation).

    This triggers `load_model()` on the MLX provider so the model is ready
    for the next `chat()` call without the user experiencing a cold-start delay.

    If reloading fails (e.g., insufficient RAM), the error is logged but not
    raised — the next `chat()` call will attempt its own lazy reload.

    Returns:
        Status dict with success/error information
    """
    global _llm_router
    router = get_llm_router()

    # Only reload MLX local models — cloud providers don't hold models in memory
    from .llm_providers import ProviderType, MLXProvider

    mlx_provider = router.providers.get(ProviderType.MLX_LOCAL)
    if mlx_provider is None:
        return {"status": "skipped", "message": "No MLX provider configured"}

    if not isinstance(mlx_provider, MLXProvider):
        return {"status": "skipped", "message": "MLX provider is not an MLXProvider instance"}

    if mlx_provider.model is not None:
        return {"status": "already_loaded", "message": "Chat LLM already loaded"}

    if not mlx_provider.is_available():
        return {"status": "unavailable", "message": "MLX not available on this system"}

    try:
        logger.info("Reloading chat LLM model: %s", mlx_provider.model_name)
        mlx_provider.load_model()
        logger.info("Chat LLM reloaded successfully: %s", mlx_provider.model_name)
        return {
            "status": "success",
            "message": f"Chat LLM reloaded: {mlx_provider.model_name}",
            "model": mlx_provider.model_name,
        }
    except Exception as e:
        logger.warning("Could not reload chat LLM: %s", e)
        return {
            "status": "error",
            "message": f"Chat LLM reload failed (will retry on next chat): {e}",
            "model": mlx_provider.model_name,
        }


def ask_majik(
    user_message: str,
    history: Optional[List[Dict[str, str]]] = None,
    generator=None,
    allow_auto_generation: bool = False,
    agent_config: Optional[Dict[str, Any]] = None,
    custom_system_prompt: Optional[str] = None,
    temperature_override: Optional[float] = None,
    max_tokens_override: Optional[int] = None,
    top_p_override: Optional[float] = None,
    on_partial: Optional[Any] = None,
) -> Dict[str, Any]:
    """
    Chat with Sterling using best available LLM provider with tool calling support

    Args:
        user_message: User's message
        history: Conversation history
        generator: ACEGenerator instance for tool execution
        allow_auto_generation: If True, Sterling can automatically call tools. If False, manual mode (no tool calling)

    Returns:
        {
            "text": "response text",
            "model": "model_name",
            "provider": "provider_name",
            "source": "local" or "cloud",
            "tool_calls": [...] (optional)
        }
    """
    router = get_llm_router(agent_config=agent_config)
    model_name = _get_model_name_from_config(router.config, router.config.provider)
    agent_temperature = _agent_config_float(agent_config, "temperature")
    agent_max_tokens = _agent_config_int(agent_config, "max_tokens")
    agent_top_p = _agent_config_float(agent_config, "top_p")
    requested_temperature = temperature_override if temperature_override is not None else agent_temperature
    requested_max_tokens = max_tokens_override if max_tokens_override is not None else agent_max_tokens
    requested_top_p = top_p_override if top_p_override is not None else agent_top_p
    has_generation_overrides = (
        requested_temperature is not None
        or requested_max_tokens is not None
        or requested_top_p is not None
    )
    if has_generation_overrides:
        resolved_temperature, resolved_max_tokens, resolved_top_p = _resolve_chat_overrides(
            model_name,
            temperature_override=requested_temperature,
            max_tokens_override=requested_max_tokens,
            top_p_override=requested_top_p,
        )
    else:
        resolved_temperature, resolved_max_tokens, resolved_top_p = (None, None, None)

    messages = build_messages(
        user_message,
        history,
        allow_auto_generation,
        provider_type=router.config.provider,
        model_name=model_name,
        custom_system_prompt=custom_system_prompt,
        agent_config=agent_config,
    )

    # Check if current provider supports tools
    provider_type = router.config.provider
    supports_tools = model_supports_tools(model_name, provider_type)
    allowed_tool_ids = _agent_tool_ids(agent_config)

    logger.debug(
        "ask_majik agent=%s provider=%s supports_tools=%s generator=%s auto_generation=%s user_message=%s",
        (agent_config or {}).get("name", "Sterling"),
        provider_type.value,
        supports_tools,
        generator is not None,
        allow_auto_generation,
        user_message[:100],
    )

    # Only use tools if:
    # 1. Provider supports tools
    # 2. Generator is available
    # 3. Auto-generation is enabled
    if supports_tools and generator is not None and allow_auto_generation and allowed_tool_ids:
        # Format tools for the current provider
        tools = format_tools_for_provider(provider_type.value, allowed_tool_names=allowed_tool_ids)
        tool_names = [t.get("name") or t.get("function", {}).get("name", "?") for t in tools]
        logger.debug("Calling LLM with %s tools: %s", len(tools), tool_names)

        try:
            # Call LLM with tools
            result = _call_llm(
                router,
                messages,
                tools=tools,
                temperature=resolved_temperature,
                max_tokens=resolved_max_tokens,
                top_p=resolved_top_p,
            )
            logger.debug(
                "LLM response received text=%s tool_calls_present=%s",
                result.get("text", "")[:100],
                "tool_calls" in result,
            )

            # Check if the model wants to use a tool
            if "tool_calls" in result and result["tool_calls"] and len(result["tool_calls"]) > 0:
                logger.debug("Tool calls detected: %s", result["tool_calls"])
                tool_results = []

                for tool_call in result["tool_calls"]:
                    tool_name = tool_call.get("name")
                    tool_input = tool_call.get("input", {})

                    logger.debug("Executing tool %s with input %s", tool_name, tool_input)

                    # Execute the tool
                    tool_result = execute_tool(tool_name, tool_input, generator)
                    logger.debug("Tool result: %s", tool_result)

                    tool_results.append({
                        "tool_name": tool_name,
                        "result": tool_result
                    })

                follow_up_messages = _build_tool_completion_messages(messages, result, tool_results)
                follow_up_result = _call_llm(
                    router,
                    follow_up_messages,
                    temperature=resolved_temperature,
                    max_tokens=resolved_max_tokens,
                    top_p=resolved_top_p,
                    on_partial=on_partial,
                )
                natural_text = follow_up_result.get("text", "").strip()
                if not natural_text:
                    natural_text = result.get("text", "").strip() or "I finished executing your requested tools."

                return {
                    "text": natural_text,
                    "model": follow_up_result.get("model", result.get("model")),
                    "provider": follow_up_result.get("provider", result.get("provider")),
                    "source": follow_up_result.get("source", result.get("source")),
                    "tool_calls": tool_results
                }
        except Exception as e:
            logger.exception("Tool calling failed: %s", e)
            raise _classify_agent_exception(e) from e

    # No tool support, no generator, or auto-generation disabled - just chat
    reason = []
    if not supports_tools:
        reason.append("provider doesn't support tools")
    if generator is None:
        reason.append("no generator available")
    if not allow_auto_generation:
        reason.append("auto-generation disabled (manual mode)")
    if not allowed_tool_ids:
        reason.append("agent has no enabled tools")

    logger.debug("Regular chat mode: %s", ", ".join(reason))
    try:
        result = _call_llm(
            router,
            messages,
            temperature=resolved_temperature,
            max_tokens=resolved_max_tokens,
            top_p=resolved_top_p,
            on_partial=on_partial,
        )
    except Exception as exc:
        raise _classify_agent_exception(exc) from exc

    return {
        "text": result.get("text", ""),
        "model": result.get("model", "unknown"),
        "provider": result.get("provider", "unknown"),
        "source": result.get("source", "llm")
    }


def fix_json_formatting(text: str) -> str:
    """
    Fix common JSON formatting issues from LLM responses.

    Uses a character-by-character state machine to properly track JSON
    string boundaries and escape literal newlines inside string values.
    The old approach (counting quotes per line) broke when lyrics contained
    quotation marks, causing the quote count to appear even on lines still
    inside a string value.

    Handles:
    1. Markdown code blocks (```json ... ```)
    2. Literal newlines in string values (converts to \\n)
    3. Unescaped quotes inside string values (escapes them)
    """
    import re

    # Remove markdown code blocks
    text = re.sub(r'```(?:json)?\s*', '', text)
    text = re.sub(r'```\s*$', '', text)

    # Find the JSON object bounds
    start = text.find('{')
    end = text.rfind('}')

    if start == -1 or end == -1:
        return text

    json_text = text[start:end + 1]

    # State-machine approach: walk character by character and escape
    # literal newlines (and problematic characters) inside JSON strings.
    #
    # JSON string context is determined by tracking brace/bracket depth,
    # colon separators, and whether we've seen an opening quote for a value.
    result = []
    i = 0
    in_string = False      # Are we inside a JSON string?
    escape_next = False    # Was previous char a backslash?

    while i < len(json_text):
        ch = json_text[i]

        if escape_next:
            # Previous char was \, this char is the escaped character
            result.append(ch)
            escape_next = False
            i += 1
            continue

        if ch == '\\' and in_string:
            result.append(ch)
            escape_next = True
            i += 1
            continue

        if ch == '"':
            if in_string:
                # Check if this quote really closes the string or is an
                # embedded quote inside a value (common in lyrics).
                # A closing quote is followed by optional whitespace then
                # one of: , } ] or end-of-string.  Anything else means
                # this is an internal quote that needs escaping.
                rest = json_text[i + 1:].lstrip()
                if rest and rest[0] not in (',', '}', ']', ':'):
                    # Internal quote inside a string value — escape it
                    result.append('\\"')
                    i += 1
                    continue
                else:
                    # Genuine closing quote
                    in_string = False
                    result.append(ch)
                    i += 1
                    continue
            else:
                # Opening a new string
                in_string = True
                result.append(ch)
                i += 1
                continue

        if ch == '\n':
            if in_string:
                # Literal newline inside a JSON string — escape it
                result.append('\\n')
            else:
                result.append(ch)
            i += 1
            continue

        if ch == '\r':
            if in_string:
                result.append('\\r')
            # else: skip bare \r outside strings
            i += 1
            continue

        if ch == '\t' and in_string:
            result.append('\\t')
            i += 1
            continue

        result.append(ch)
        i += 1

    return ''.join(result)


def _extract_fields_by_regex(text: str) -> Dict[str, Any]:
    """Last-resort field extraction using regex patterns.

    When the LLM produces JSON that is too malformed for json.loads even
    after repair passes, we pull individual field values directly from the
    raw text.  This handles cases where lyrics contain unescaped quotes,
    mismatched braces, etc.
    """
    import re
    params: Dict[str, Any] = {}

    # caption — required
    m = re.search(r'"caption"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
    if m:
        params["caption"] = m.group(1).replace("\\n", "\n")

    # bpm — optional, numeric
    m = re.search(r'"bpm"\s*:\s*(\d+)', text)
    if m:
        params["bpm"] = int(m.group(1))

    # key — optional
    m = re.search(r'"key"\s*:\s*"((?:[^"\\]|\\.)*)"', text)
    if m:
        val = m.group(1)
        if val.lower() not in ("", "not provided", "not mentioned", "n/a", "none", "null"):
            params["key"] = val

    # duration — optional, numeric
    m = re.search(r'"duration"\s*:\s*(\d+(?:\.\d+)?)', text)
    if m:
        params["duration"] = float(m.group(1))

    # lyrics — optional, greedy (may span many escaped newlines)
    # Use the last "lyrics" key occurrence for best chance of getting
    # the full value (retries append more text).
    for m in re.finditer(r'"lyrics"\s*:\s*"((?:[^"\\]|\\.)*)"', text):
        val = m.group(1).replace("\\n", "\n")
        if val.strip().lower() not in ("", "not provided", "not mentioned", "n/a", "none", "null"):
            params["lyrics"] = val

    return params


def _validate_extracted_params(params: Dict[str, Any]) -> List[str]:
    """
    Validate extracted parameters to detect placeholder text or invalid values.

    Returns:
        List of validation error messages (empty list if valid)
    """
    import re
    errors = []

    # ULTRA-STRICT placeholder text patterns that indicate the model copied examples instead of extracting
    # These patterns are FORBIDDEN in ANY field
    # NOTE: Be careful not to match common song lyrics phrases!
    placeholder_patterns = [
        r"from\s+(the\s+)?conversation",  # "from conversation", "from the conversation"
        r"description\s+here",
        r"lyrics\s+here",
        r"actual\s+lyrics",
        r"your\s+(caption|description|lyrics|text)",  # Only match specific placeholder words, NOT "your dreams", "your love", etc.
        r"placeholder",
        r"insert\s+(your|the|a)\s+",  # "insert your lyrics", NOT just "insert" alone
        r"add\s+(your|the|a)\s+(description|lyrics|caption)",  # specific placeholder patterns
        r"(lyrics|description|caption)\s+here:",  # "Lyrics here:", "Description here:"
        r"mentioned\s+in\s+(the\s+)?conversation",
        r"discussed\s+in\s+(the\s+)?conversation",
        r"based\s+on\s+(the\s+)?conversation",
        r"extracted\s+from\s+(the\s+)?conversation",
        r"\[(insert|add|your|description|lyrics|caption|text)\s*(here)?\]",  # Specific placeholder brackets, NOT [Verse 1]
        r"replace\s+with\s+(your|the|actual)",
        r"fill\s+in\s+(the|your)",
    ]

    # Compile regex patterns for efficiency
    compiled_patterns = [(p, re.compile(p, re.IGNORECASE)) for p in placeholder_patterns]

    # Helper function to check a field for placeholder text
    def check_field(field_name: str, field_value: Any, is_critical: bool = False) -> bool:
        """Check a single field for placeholder text. Returns True if placeholder found."""
        if field_value is None or field_value == "":
            return False

        value_str = str(field_value).strip()
        value_lower = value_str.lower()

        # Check each pattern
        for pattern_str, pattern_regex in compiled_patterns:
            if pattern_regex.search(value_str):
                match_text = pattern_regex.search(value_str).group()
                errors.append(
                    f"❌ PLACEHOLDER DETECTED in {field_name}: '{match_text}' found in '{value_str[:200]}'"
                )
                logger.error("🚨 VALIDATION FAILURE: Field '%s' contains placeholder pattern '%s'",
                           field_name, pattern_str)
                logger.error("🚨 Rejected value: %s", value_str)
                return True

        return False

    # Check caption for placeholder text (CRITICAL - this is required)
    if "caption" in params:
        check_field("caption", params["caption"], is_critical=True)

        # Caption should have some substance (at least 3 words)
        caption_words = params["caption"].split()
        if len(caption_words) < 3:
            errors.append(f"Caption too short/vague (only {len(caption_words)} words): '{params['caption']}'")
            logger.warning("🔧 Caption validation: Too short - %s words", len(caption_words))

    # Check lyrics for placeholder text (MOST CRITICAL)
    if "lyrics" in params and params["lyrics"]:
        check_field("lyrics", params["lyrics"], is_critical=True)

        # Lyrics should have some substance (at least 20 characters)
        lyrics_len = len(str(params["lyrics"]).strip())
        if lyrics_len < 20:
            errors.append(f"Lyrics too short ({lyrics_len} chars): '{params['lyrics']}'")
            logger.warning("🔧 Lyrics validation: Too short - %s chars", lyrics_len)

    # Check key format if present
    if "key" in params and params["key"]:
        check_field("key", params["key"])

    # Check ALL other text fields for placeholders (catch unknown fields)
    for field_name, field_value in params.items():
        if field_name not in ["caption", "lyrics", "key", "duration", "count", "bpm"] and isinstance(field_value, str):
            if check_field(field_name, field_value):
                logger.warning("🔧 Unknown field '%s' contains placeholder text", field_name)

    if errors:
        logger.error("🚨 VALIDATION FAILED with %d errors:", len(errors))
        for error in errors:
            logger.error("   - %s", error)

    return errors


def _msg_content(msg: Dict) -> str:
    """Safely get message content as a string (handles dict/list content from tool-use messages)."""
    content = msg.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        # Multi-part content (e.g. [{"type": "text", "text": "..."}])
        parts = []
        for part in content:
            if isinstance(part, dict):
                parts.append(part.get("text", str(part)))
            else:
                parts.append(str(part))
        return "\n".join(parts)
    if isinstance(content, dict):
        return content.get("text", str(content))
    return str(content)


def _sanitize_messages(messages: List[Dict]) -> List[Dict]:
    """Ensure all message content values are plain strings.
    Tokenizers (apply_chat_template) call .strip() on content and crash on dicts."""
    sanitized = []
    for msg in messages:
        content = msg.get("content", "")
        if not isinstance(content, str):
            logger.warning("🔧 Non-string message content (type=%s role=%s): %s",
                          type(content).__name__, msg.get("role"), repr(content)[:200])
            content = _msg_content(msg)
        sanitized.append({**msg, "content": content})
    return sanitized


def _extract_lyrics_from_conversation(conversation_history: List[Dict[str, str]]) -> Optional[str]:
    """
    Extract lyrics from conversation using pattern matching.

    Looks for common lyrics indicators like:
    - Verse/Chorus/Bridge markers in various formats:
      - Markdown bold: **Verse 1:** (colon inside bold)
      - Plain text: Verse 1:
      - Bracketed: [Verse 1]
    - Multiple lines of text that look like song lyrics
    - Content after "Here are the lyrics:" or similar

    Strategy: Search the LAST assistant message first (most recent song).
    Only fall back to the full conversation if nothing is found there.

    Returns:
        Extracted lyrics string or None if not found
    """
    import re

    # Search the LAST assistant message first — this is the most recent song
    # and avoids mixing lyrics from previous songs or chat messages in between.
    last_assistant_text = None
    for msg in reversed(conversation_history):
        text_content = _msg_content(msg)
        if msg.get("role") == "assistant" and text_content.strip():
            last_assistant_text = text_content
            break

    # Build search texts: prefer last assistant message, fall back to full conversation
    search_texts = []
    if last_assistant_text:
        search_texts.append(("last assistant message", last_assistant_text))
    # Full conversation as fallback (but only if last assistant message doesn't have lyrics)
    full_text = "\n".join([
        _msg_content(msg) for msg in conversation_history
    ])
    search_texts.append(("full conversation", full_text))

    # Common section names for song structure (ONLY actual song parts)
    section_names = ["Verse", "Chorus", "Bridge", "Hook", "Intro", "Outro", "Pre-Chorus", "Interlude", "Refrain", "Break"]
    section_pattern = "|".join(section_names)

    # Commentary headers to EXCLUDE — these look like song sections but aren't lyrics
    commentary_names = [
        "Interpretation", "Arrangement", "Remix", "Connection", "Guide",
        "Production", "Notes", "Instrumentation", "Structure", "Overview",
        "Inspiration", "Concept", "Theme", "Analysis", "Description",
        "Final Touches", "Summary", "Tips", "Implementation", "Direction",
        "Mood", "Feel", "Vibe", "Suggestions", "Parameters", "Details",
    ]
    commentary_pattern = re.compile(
        r"\*\*(?:" + "|".join(commentary_names) + r").*?\*\*",
        re.IGNORECASE
    )

    # Production/arrangement terminology — lines containing these words are
    # arrangement notes, NOT lyrics.  Used by the per-line content filter
    # below to strip out production bullets that sneak into extracted lyrics
    # when the LLM mixes arrangement/production notes with song content
    # (BUG-003).
    _production_term_re = re.compile(
        r"\b(?:"
        # Tempo / key / time
        r"BPM|bpm|tempo|key\s+of\s+[A-G]|time\s+signature"
        # Arrangement / production concepts
        r"|instrumentation|arrangement|orchestration"
        r"|production\s+(?:note|tip|style|value)"
        r"|sound\s+design|sonic\s+palette"
        # Specific instruments / sound sources used as directions
        r"|synthesizer|synth\s+pad|808s?\b|hi[\-\s]?hats?"
        r"|drum\s+(?:machine|pattern|loop|fill|kit|break)"
        r"|bass\s+(?:line|drop|boost|synth)|sub[\-\s]?bass"
        # Mixing / mastering / effects
        r"|reverb|delay|compression|sidechain|EQ\b|equalization"
        r"|panning|stereo\s+field|master(?:ing)|mix(?:ing)\b"
        r"|filter\s+sweep|automation|fade[\-\s]?(?:in|out)"
        # Musical direction terms (not lyrics)
        r"|crescendo|decrescendo|diminuendo"
        r"|chord\s+progression|strum\s+pattern|arpeggio"
        # Layering / processing directions
        r"|add\s+(?:a\s+)?(?:layer|pad|choir|strings|brass|organ|percussion)"
        r"|layer(?:ing)?\s+(?:with|of|in)"
        r"|vocal\s+(?:effect|processing|chop|sample|harmony|layer)"
        r"|sample\s+(?:chop|flip|loop|pack|rate)"
        r"|swing\s+(?:feel|rhythm|percentage)"
        r"|quantize|transpose"
        r")\b",
        re.IGNORECASE,
    )

    # Standalone parameter lines like "**BPM:** 120" or "**Key:** C minor"
    _param_line_re = re.compile(
        r"^\*{0,2}(?:BPM|Key|Duration|Tempo|Time Signature|Genre|Style|Mood|Energy|Instruments?)\*{0,2}\s*:\s*",
        re.IGNORECASE,
    )

    # Patterns to match section headers in different formats
    # Each pattern captures the header for identification
    header_patterns = [
        # Markdown bold: **Verse 1:** or **Verse 1 (0:00 - 0:30):**
        re.compile(rf"\*\*({section_pattern})\s*(\d*)\s*(?:\([^)]*\))?\s*[-–—]?\s*[^*]*:\*\*", re.IGNORECASE),
        # Markdown bold simpler: **Verse 1:**
        re.compile(rf"\*\*({section_pattern})\s*(\d*):\*\*", re.IGNORECASE),
        # Plain text with colon: Verse 1:
        re.compile(rf"^({section_pattern})\s*(\d*):$", re.IGNORECASE | re.MULTILINE),
        # Bracketed: [Verse 1]
        re.compile(rf"\[({section_pattern})\s*(\d*)\]", re.IGNORECASE),
    ]

    # Explicit "here are the lyrics" patterns
    # "FULL LYRICS" is a common marker LLMs use to separate arrangement notes from actual lyrics
    explicit_lyrics_patterns = [
        r"(?:FULL\s+LYRICS[:\s]*\n)(.*?)(?=\n\n(?:Want|Would|Let|I can)|$)",
        r"(?:here\s+are\s+(?:the\s+)?(?:full\s+)?lyrics[:\s]*\n)(.*?)(?=\n\n(?:Want|Would|Let|I can)|$)",
        r"(?:lyrics[:\s]*\n\n?)(.*?)(?=\n\n(?:Want|Would|Let|I can)|$)",
    ]

    # Search each text source in order: last assistant message first, then full conversation
    for source_name, text in search_texts:
        # FIRST: Check for explicit "FULL LYRICS" marker — most reliable signal
        # LLMs often put arrangement notes first, then "FULL LYRICS" before actual lyrics
        for pattern in explicit_lyrics_patterns:
            match = re.search(pattern, text, re.IGNORECASE | re.DOTALL)
            if match:
                lyrics = match.group(1).strip()
                if len(lyrics) > 50:
                    logger.debug("Found lyrics via explicit marker (%s): %d chars", source_name, len(lyrics))
                    return lyrics

        # SECOND: Try section header extraction (Verse/Chorus/Bridge pattern)
        found_sections = []
        for pattern in header_patterns:
            for match in pattern.finditer(text):
                # Skip if this position is inside a commentary header
                if commentary_pattern.search(text[max(0, match.start()-5):match.end()+30]):
                    continue
                found_sections.append({
                    "start": match.start(),
                    "end": match.end(),
                    "header": match.group(0),
                    "section_type": match.group(1),
                    "number": match.group(2) if len(match.groups()) > 1 else ""
                })

        if found_sections:
            # Sort by position in text
            found_sections.sort(key=lambda x: x["start"])
            logger.debug("Found %d lyric sections in %s: %s",
                        len(found_sections), source_name,
                        [s["header"] for s in found_sections])

            # Extract content between sections
            lyrics_parts = []
            for i, section in enumerate(found_sections):
                # Start of content is after the header
                content_start = section["end"]

                # End of content is start of next section, or end of reasonable lyrics area
                if i + 1 < len(found_sections):
                    content_end = found_sections[i + 1]["start"]
                else:
                    # For last section, find a reasonable end point
                    # Look for common conversation continuations
                    remaining = text[content_start:]
                    end_markers = [
                        re.search(r"\n\n(?:Want|Would|Should|Let me|Ready|I can|I'll|Here's|That's|Feel free|To add|I've woven|The sparse)", remaining),
                        re.search(r"\n\n[A-Z][a-z]+ (?:you|me|to|that|this|it)", remaining),
                        # Stop at any markdown bold header that isn't a song section
                        re.search(r"\n\n\*\*(?!" + section_pattern + r")[\w\s]+:?\*\*", remaining, re.IGNORECASE),
                    ]
                    valid_ends = [m.start() for m in end_markers if m]
                    if valid_ends:
                        content_end = content_start + min(valid_ends)
                    else:
                        content_end = len(text)

                content = text[content_start:content_end].strip()
                if content:
                    # Clean content: remove commentary lines (bullets, descriptions, non-lyric text)
                    cleaned_lines = []
                    for line in content.split("\n"):
                        stripped = line.strip()
                        # Skip bullet points in all formats (arrangement/production notes)
                        if stripped.startswith("* ") or stripped.startswith("- ") or stripped.startswith("• ") or stripped.startswith("· "):
                            continue
                        # Skip indented bullet points (sub-bullets like "    • Add choir pad")
                        if re.match(r"^\s+[•·\-\*]\s+", line):
                            continue
                        # Skip numbered list items (e.g. "1. Use 808 bass")
                        if re.match(r"^\d+[\.\)]\s+", stripped):
                            continue
                        # Skip lines that are clearly meta-commentary (any markdown bold header that isn't a song section)
                        if re.match(r"^\*\*(?!" + section_pattern + r")[\w\s]+:?\*\*", stripped, re.IGNORECASE):
                            continue
                        # Skip standalone parameter lines like "**BPM:** 120" or "Key: C minor"
                        if _param_line_re.match(stripped):
                            continue
                        # Skip lines containing production/arrangement terminology (BUG-003)
                        # These are arrangement directions, not lyrics — e.g.
                        #   "Add a synth pad layer with reverb"
                        #   "Chord progression: Am - F - C - G"
                        #   "Use sidechain compression on the bass"
                        if _production_term_re.search(stripped):
                            continue
                        # Skip conversational LLM lines (advice, suggestions, sign-offs)
                        if re.match(r"^(?:Feel free|To add|I've |The sparse|Let me know|If you|I can|I'll|Here's|That's|This |Want me)", stripped, re.IGNORECASE):
                            continue
                        # Skip parenthetical descriptions like "(slow, jazzy vibe)"
                        if re.match(r"^\(.*(?:vibe|style|feel|tempo|energy|mood).*\)$", stripped, re.IGNORECASE):
                            continue
                        cleaned_lines.append(line)
                    content = "\n".join(cleaned_lines).strip()
                if content:
                    lyrics_parts.append(section["header"] + "\n" + content)

            if lyrics_parts:
                combined = "\n\n".join(lyrics_parts)
                if len(combined) > 50:  # Minimum length for valid lyrics
                    logger.debug("Found lyrics via section extraction (%s): %d chars", source_name, len(combined))
                    return combined

    logger.debug("No lyrics found in conversation via fallback extraction")
    return None


def extract_music_parameters(conversation_history: List[Dict[str, str]]) -> Dict[str, Any]:
    """
    Extract music generation parameters from conversation history.

    Strategy:
    - Default: Use a dedicated extraction model (Qwen 3.5 4B) configured via
      MAJIK_EXTRACTION_MODEL env var. Fast, accurate, strong instruction following.
    - Optional: Set MAJIK_EXTRACTION_MODEL=chat to use the chat model instead
      (no model swap needed, full conversation context).
    """
    # Log what we received for debugging
    logger.debug("🔧 extract_music_parameters called with %d messages", len(conversation_history))
    for i, msg in enumerate(conversation_history):
        content = msg.get("content", "")
        logger.debug("🔧   msg[%d] role=%s content_type=%s len=%s preview=%s",
                     i, msg.get("role"), type(content).__name__,
                     len(content) if isinstance(content, str) else "N/A",
                     repr(content)[:100] if isinstance(content, str) else repr(content)[:200])

    # Sanitize conversation history — ensure all content values are strings
    conversation_history = _sanitize_messages(conversation_history)

    global _engineer_router
    import json
    import re
    from .llm_providers import LLMConfig, LLMRouter, ProviderType
    from .model_configs import (
        DEFAULT_EXTRACTION_MODEL,
        ENGINEER_SYSTEM_PROMPT,
        ENGINEER_INFERENCE_PARAMS
    )

    # Check which extraction model is configured
    # Default: Qwen 3.5 4B (fast, accurate, strong instruction following)
    # Set MAJIK_EXTRACTION_MODEL=chat to use the chat model instead
    extraction_model_setting = os.getenv("MAJIK_EXTRACTION_MODEL", DEFAULT_EXTRACTION_MODEL).strip()
    if not extraction_model_setting:
        extraction_model_setting = DEFAULT_EXTRACTION_MODEL
    use_chat_model_for_extraction = extraction_model_setting.lower() == "chat"

    custom_prompt_map = _get_custom_prompt_map()

    if use_chat_model_for_extraction:
        # ── Use the chat model directly (preferred approach) ──
        # No model swap needed — the chat model is already loaded with full context
        router = get_llm_router()
        chat_model_name = _get_model_name_from_config(router.config, router.config.provider)

        logger.info("🔧 The Engineer: Using chat model for extraction: %s", chat_model_name)

        engineer_prompt = (
            custom_prompt_map.get(f"engineer::{chat_model_name}")
            or custom_prompt_map.get(chat_model_name)
            or ENGINEER_SYSTEM_PROMPT
        )

        messages = [{"role": "system", "content": engineer_prompt}]
        messages.extend(conversation_history)
        messages.append({
            "role": "user",
            "content": PARAMETER_EXTRACTION_PROMPT
        })
        messages = _sanitize_messages(messages)

        try:
            result = router.chat(
                messages,
                temperature=0.1,  # Low temp for accurate extraction
                max_tokens=ENGINEER_INFERENCE_PARAMS["max_tokens"],
                top_p=ENGINEER_INFERENCE_PARAMS.get("top_p", 0.9),
                skip_harmony_parsing=True,
                use_chat_template=True,
            )
        except Exception as e:
            logger.error("🔧 Chat model extraction failed: %s", str(e))
            logger.exception("Full traceback:")
            raise

    else:
        # ── Use a dedicated extraction model (NuExtract, Granite, etc.) ──
        extraction_model = extraction_model_setting

        # Unload chat model first to free RAM for dedicated Engineer
        chat_unload = unload_chat_llm()
        logger.info("🔧 Chat model unloaded: %s", chat_unload.get("message", "done"))

        logger.info(
            "🔧 The Engineer loading dedicated extraction model: %s",
            extraction_model
        )

        # Check if we need to create/reload the engineer router
        if _engineer_router is None or _engineer_router.config.mlx_model != extraction_model:
            if _engineer_router is not None:
                _engineer_router.unload_chat_models()
                logger.info("🔧 Previous Engineer model unloaded")

            extraction_config = LLMConfig(
                provider=ProviderType.MLX_LOCAL,
                mlx_model=extraction_model,
                mlx_temperature=0.0,
                mlx_max_tokens=ENGINEER_INFERENCE_PARAMS["max_tokens"],
            )
            _engineer_router = LLMRouter(extraction_config)
            logger.info("🔧 New Engineer router created")

        engineer_router = _engineer_router

        # Standard chat format for all extraction models
        engineer_prompt = (
            custom_prompt_map.get(f"engineer::{extraction_model}")
            or custom_prompt_map.get(extraction_model)
            or ENGINEER_SYSTEM_PROMPT
        )
        messages = [{"role": "system", "content": engineer_prompt}]
        messages.extend(conversation_history)
        messages.append({
            "role": "user",
            "content": PARAMETER_EXTRACTION_PROMPT
        })
        messages = _sanitize_messages(messages)

        try:
            result = engineer_router.chat(
                messages,
                temperature=0.0,
                max_tokens=ENGINEER_INFERENCE_PARAMS["max_tokens"],
                top_p=ENGINEER_INFERENCE_PARAMS.get("top_p", 0.9),
                skip_harmony_parsing=True,
                use_chat_template=True,
            )
        except ModelDownloadError:
            # Model isn't downloaded yet — give a clear, specific message
            raise MajikAgentError(
                code="EXTRACTION_MODEL_DOWNLOAD",
                message=f"Extraction model '{extraction_model}' is not downloaded yet.",
                fix="Download the extraction model in Settings > LLM, or switch to using the chat model for extraction.",
                detail=f"Model '{extraction_model}' needs to be downloaded before it can be used for parameter extraction.",
            )
        except Exception as e:
            logger.error("🔧 Dedicated extraction model '%s' failed: %s", extraction_model, str(e))
            logger.exception("Full traceback:")
            # Fallback to chat model
            logger.error("Falling back to chat model for extraction")
            primary_error = str(e)
            try:
                router = get_llm_router()
                messages_fallback = [{"role": "system", "content": ENGINEER_SYSTEM_PROMPT}]
                messages_fallback.extend(conversation_history)
                messages_fallback.append({"role": "user", "content": PARAMETER_EXTRACTION_PROMPT})
                messages_fallback = _sanitize_messages(messages_fallback)
                result = router.chat(
                    messages_fallback,
                    temperature=0.2,
                    max_tokens=2000,
                    skip_harmony_parsing=True,
                    use_chat_template=True,
                )
            except ModelDownloadError as dl_err:
                logger.error("❌ Chat model also needs downloading: %s", str(dl_err))
                raise MajikAgentError(
                    code="EXTRACTION_MODEL_DOWNLOAD",
                    message=f"Extraction model '{extraction_model}' failed and chat model is also not available.",
                    fix="Download the required models in Settings > LLM.",
                    detail=f"Extraction model error: {primary_error}. Chat model error: {dl_err}",
                )
            except Exception as fallback_error:
                logger.error("❌ Fallback to chat model also failed: %s", str(fallback_error))
                logger.exception("Fallback traceback:")
                raise MajikAgentError(
                    code="EXTRACTION_FAILED",
                    message=f"Parameter extraction failed (model: {extraction_model}).",
                    fix="Try restarting the backend in Settings, or switch extraction model in Settings > LLM.",
                    detail=f"Extraction model error: {primary_error}. Chat model fallback error: {fallback_error}",
                )

    response_text = result.get("text", "") if isinstance(result, dict) else str(result)
    logger.debug(
        "Parameter extraction response length=%s model=%s provider=%s text=%s",
        len(response_text),
        result.get("model", "unknown"),
        result.get("provider", "unknown"),
        response_text,
    )

    # Fix JSON formatting issues (literal newlines in lyrics, markdown blocks, etc.)
    cleaned_text = fix_json_formatting(response_text)
    if cleaned_text != response_text:
        logger.debug("Applied JSON formatting fixes")

    # Try to complete truncated JSON (common with small context models like NuExtract)
    def try_complete_json(text: str) -> str:
        """Attempt to complete truncated JSON by adding missing closing braces/quotes."""
        if not text.strip():
            return text
        text = text.strip()
        # If starts with { but doesn't end with }, try to complete it
        if text.startswith('{') and not text.rstrip().endswith('}'):
            logger.warning("🔧 Detected truncated JSON, attempting completion...")
            # Count unclosed braces and quotes
            open_braces = text.count('{') - text.count('}')
            # Check if we're in the middle of a string value
            # Find last quote and check if it's opening or closing
            in_string = False
            escape_next = False
            for char in text:
                if escape_next:
                    escape_next = False
                    continue
                if char == '\\':
                    escape_next = True
                elif char == '"':
                    in_string = not in_string
            # Try to close properly
            completion = ""
            if in_string:
                completion += '"'  # Close the string
            # Remove trailing comma if present
            text = text.rstrip().rstrip(',')
            completion += '}' * open_braces
            completed = text + completion
            logger.info("🔧 Completed JSON: added '%s'", completion)
            return completed
        return text

    cleaned_text = try_complete_json(cleaned_text)

    json_match = re.search(r"\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", cleaned_text)
    if not json_match:
        logger.warning("🔧 The Engineer: No JSON found in first attempt (length=%d, preview='%s'), trying retry",
                      len(cleaned_text), cleaned_text[:200] if cleaned_text else "(empty)")
        # Retry once — use the same router that produced the first attempt
        retry_router = get_llm_router()
        retry_messages = [
            {"role": "system", "content": ENGINEER_SYSTEM_PROMPT},
            {"role": "user", "content": "Return ONLY a valid JSON object with the required fields. No extra text."}
        ]
        retry_messages.extend(conversation_history)
        retry_messages.append({"role": "user", "content": PARAMETER_EXTRACTION_PROMPT})
        retry_messages = _sanitize_messages(retry_messages)
        retry_result = retry_router.chat(
            retry_messages,
            temperature=0.0,
            max_tokens=1000,
            top_p=0.9,
            skip_harmony_parsing=True,
            use_chat_template=True,
        )
        retry_text = retry_result.get("text", "") if isinstance(retry_result, dict) else str(retry_result)
        logger.debug("Retry response length=%s text=%s", len(retry_text), retry_text)
        # Fix JSON formatting in retry too
        retry_text = fix_json_formatting(retry_text)
        # Try to complete truncated JSON
        retry_text = try_complete_json(retry_text)
        json_match = re.search(r"\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", retry_text)
        if not json_match:
            logger.error("🔧 The Engineer: Retry also failed to find JSON (preview='%s')",
                        retry_text[:200] if retry_text else "(empty)")
            # Provide more helpful error message
            if not cleaned_text and not retry_text:
                raise ValueError("Extraction model returned empty response. The model may need to be downloaded first. Go to Settings > LLM to download the extraction model.")
            else:
                raise ValueError(f"No JSON found in extraction response. Model returned: '{(retry_text or cleaned_text)[:100]}...'  Try restarting the backend.")

    try:
        params = json.loads(json_match.group())
    except json.JSONDecodeError as exc:
        # Try to repair common JSON issues
        json_text = json_match.group()
        logger.warning("🔧 JSON parse failed, attempting repair: %s", exc)
        logger.debug("🔧 Malformed JSON: %s", json_text[:500])

        # Repair pass 1: re-run fix_json_formatting on the extracted JSON
        # (the regex may have pulled a substring that still has raw newlines)
        repaired = fix_json_formatting(json_text)

        # Repair pass 2: add missing commas between key-value pairs
        repaired = re.sub(r'"\s*\n\s*"', '",\n"', repaired)   # "value"\n"key" -> "value",\n"key"
        repaired = re.sub(r'(\d)\s*\n\s*"', r'\1,\n"', repaired)  # 123\n"key" -> 123,\n"key"
        repaired = re.sub(r'(true|false|null)\s*\n\s*"', r'\1,\n"', repaired)
        repaired = re.sub(r',\s*}', '}', repaired)  # trailing commas

        try:
            params = json.loads(repaired)
            logger.info("🔧 JSON repair successful (pass 1+2)!")
        except json.JSONDecodeError:
            # Repair pass 3: regex-based field extraction as last resort.
            # Pull individual fields from the raw LLM text instead of
            # relying on the JSON being well-formed.
            logger.warning("🔧 JSON repair failed, trying regex field extraction")
            raw = cleaned_text
            params = _extract_fields_by_regex(raw)
            if params and "caption" in params:
                logger.info("🔧 Regex field extraction successful!")
            else:
                raise ValueError(f"Failed to parse parameters: {exc}") from exc

    # Coerce all param values to strings — LLMs sometimes return nested objects
    for key in list(params.keys()):
        val = params[key]
        if isinstance(val, dict):
            logger.warning("🔧 Param '%s' is dict, coercing to string: %s", key, repr(val)[:200])
            if key == "lyrics":
                # LLM returned lyrics as {"Verse 1": "...", "Chorus": "..."} — flatten to text
                parts = []
                for section_name, section_text in val.items():
                    section_text = str(section_text).replace("\\n", "\n")
                    parts.append(f"[{section_name}]\n{section_text}")
                params[key] = "\n\n".join(parts)
            else:
                params[key] = val.get("text", val.get("value", str(val)))
        elif isinstance(val, list):
            logger.warning("🔧 Param '%s' is list, coercing to string: %s", key, repr(val)[:200])
            params[key] = "\n".join(str(item) for item in val)
        elif val is not None and not isinstance(val, (str, int, float, bool)):
            logger.warning("🔧 Param '%s' has unexpected type %s, coercing", key, type(val).__name__)
            params[key] = str(val)

    if "caption" not in params:
        raise ValueError("Missing required field: caption")

    # Clean up optional fields with "not provided" / "none" / "n/a" type values
    # These are valid responses from NuExtract when no value exists in conversation
    OPTIONAL_FIELDS = ["lyrics", "bpm", "key"]
    EMPTY_VALUE_INDICATORS = [
        "not provided", "not mentioned", "not specified", "not available",
        "not explicitly", "is not", "are not", "wasn't", "weren't",
        "none", "n/a", "null", "unknown", "unspecified",
        "no lyrics", "no bpm", "no key",
        "typical", "usually", "often", "commonly", "generally",  # NuExtract gives explanations
        "range from", "ranges from", "between",  # BPM ranges
    ]

    for field in OPTIONAL_FIELDS:
        if field in params:
            field_value = str(params[field]).strip().lower()
            # Skip empty-value check for lyrics that are clearly actual lyrics (> 100 chars)
            # Short values like "not provided" or "none" are the target here, not real content
            if field == "lyrics" and len(field_value) > 100:
                continue
            # Check for empty indicators
            if any(indicator in field_value for indicator in EMPTY_VALUE_INDICATORS) or field_value in ["", "null", "none"]:
                logger.info("🔧 Removing optional field '%s' with empty/not-provided value: '%s'", field, params[field])
                del params[field]
            # Special check for key field - must be a valid musical key, not an explanation
            elif field == "key" and len(field_value) > 20:
                # Valid keys are short like "C major", "A minor", "F# minor" - not long explanations
                logger.info("🔧 Removing 'key' field - looks like explanation, not a key: '%s'", params[field][:50])
                del params[field]

    # Validate for placeholder text and invalid values
    logger.debug("🔍 Running validation on extracted params: %s", params)
    validation_errors = _validate_extracted_params(params)
    if validation_errors:
        logger.error("🚨 VALIDATION FAILED - The Engineer returned PLACEHOLDER TEXT!")
        logger.error("🚨 Errors found: %s", "; ".join(validation_errors))
        logger.error("🚨 Problematic extraction: %s", params)
        logger.error("🚨 Attempting anti-placeholder retry...")

        # If validation fails, try ONE more time with an ultra-strict anti-placeholder prompt
        strict_retry_router = get_llm_router()
        strict_retry_messages = [
            {"role": "system", "content": ENGINEER_SYSTEM_PROMPT},
        ]
        strict_retry_messages.extend(conversation_history)
        strict_retry_messages.append({
            "role": "user",
            "content": PARAMETER_EXTRACTION_PROMPT + "\n\nIMPORTANT: Use REAL values from the conversation. Do NOT use placeholder text like 'description here' or 'lyrics from conversation'. Copy actual content word-for-word."
        })
        strict_retry_messages = _sanitize_messages(strict_retry_messages)

        strict_retry_result = strict_retry_router.chat(
            strict_retry_messages,
            temperature=0.0,
            max_tokens=700,
            top_p=0.9,
            skip_harmony_parsing=True,
            use_chat_template=True,
        )

        strict_retry_text = strict_retry_result.get("text", "") if isinstance(strict_retry_result, dict) else str(strict_retry_result)
        strict_retry_text = fix_json_formatting(strict_retry_text)
        strict_json_match = re.search(r"\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}", strict_retry_text)

        if strict_json_match:
            try:
                retry_params = json.loads(strict_json_match.group())
                retry_validation_errors = _validate_extracted_params(retry_params)

                if not retry_validation_errors:
                    logger.info("🔧 Anti-placeholder retry succeeded!")
                    params = retry_params
                    validation_errors = []
                else:
                    logger.warning("🔧 Anti-placeholder retry also failed: %s", "; ".join(retry_validation_errors))
            except json.JSONDecodeError:
                logger.warning("🔧 Anti-placeholder retry produced invalid JSON")

        # If still has validation errors, raise exception
        if validation_errors:
            raise ValueError(f"Extraction validation failed: {'; '.join(validation_errors)}")

    params.setdefault("duration", 90)

    # Force count=1 — variant count is controlled by the Swift UI, not extraction
    params["count"] = 1

    # Robust parsing for duration (might be "3:30" or "210 seconds" or "3.5 minutes" or "2 and a half minutes")
    import re
    duration_str = str(params["duration"]).strip().lower()
    duration_seconds = None

    # Check for MM:SS format first (e.g., "3:30", "1:30")
    time_match = re.search(r'(\d+):(\d+)', duration_str)
    if time_match:
        minutes = int(time_match.group(1))
        seconds = int(time_match.group(2))
        duration_seconds = minutes * 60 + seconds
        logger.info("🔧 Parsed duration MM:SS format: %s -> %ds", duration_str, duration_seconds)
    else:
        # Check for verbal fractions: "2 and a half minutes", "one and a half minutes", "a minute and a half"
        verbal_half_match = re.search(
            r'(\d+)\s+and\s+(?:a\s+)?half\s*(?:min|minute)', duration_str
        )
        if verbal_half_match:
            minutes = int(verbal_half_match.group(1)) + 0.5
            duration_seconds = int(minutes * 60)
            logger.info("🔧 Parsed duration verbal fraction: %s -> %ds", duration_str, duration_seconds)
        elif re.search(r'(?:a\s+)?minute\s+and\s+(?:a\s+)?half', duration_str):
            duration_seconds = 90
            logger.info("🔧 Parsed duration 'a minute and a half': %s -> %ds", duration_str, duration_seconds)
        elif re.search(r'half\s+(?:a\s+)?(?:min|minute)', duration_str):
            duration_seconds = 30
            logger.info("🔧 Parsed duration 'half a minute': %s -> %ds", duration_str, duration_seconds)
        else:
            # Check for minutes with decimal or integer (e.g., "3 minutes", "3 min", "2.5 minutes")
            min_match = re.search(r'(\d+(?:\.\d+)?)\s*(?:min|minute)', duration_str)
            if min_match:
                minutes = float(min_match.group(1))
                duration_seconds = int(minutes * 60)
                logger.info("🔧 Parsed duration minutes: %s -> %ds", duration_str, duration_seconds)
            else:
                # Just extract the number (assume seconds if no unit)
                num_match = re.search(r'\d+(?:\.\d+)?', duration_str)
                if num_match:
                    duration_seconds = float(num_match.group())
                    # If it's a small number (1-10) without "sec", assume it's minutes
                    if duration_seconds <= 10 and "sec" not in duration_str:
                        logger.info("🔧 Small duration %.2f assumed to be minutes, converting to %ds", duration_seconds, int(duration_seconds * 60))
                        duration_seconds = int(duration_seconds * 60)

    if duration_seconds is not None:
        params["duration"] = int(max(30, min(600, duration_seconds)))
    else:
        params["duration"] = 90  # Default
        logger.warning("🔧 Could not parse duration: %s, using default 90s", duration_str)

    if "bpm" in params and params["bpm"] is not None:
        # Handle BPM that might be a range like "140-160" or text like "140 bpm"
        bpm_str = str(params["bpm"]).strip()
        import re
        # Extract first number from string (handles "140-160", "140 bpm", "~140", etc.)
        bpm_match = re.search(r'\d+', bpm_str)
        if bpm_match:
            params["bpm"] = max(60, min(200, int(bpm_match.group())))
        else:
            # Can't parse BPM, remove it
            del params["bpm"]
            logger.warning("🔧 Could not parse BPM value: %s, removing field", bpm_str)

    # LYRICS FALLBACK: Always run regex extraction and prefer it when it finds more
    # Small models (Llama 3.2 3B, Granite) often truncate or skip lyrics in JSON output
    regex_lyrics = _extract_lyrics_from_conversation(conversation_history)
    extracted_lyrics = params.get("lyrics", "")
    if not isinstance(extracted_lyrics, str):
        extracted_lyrics = str(extracted_lyrics) if extracted_lyrics else ""
    extracted_len = len(extracted_lyrics.strip()) if extracted_lyrics else 0
    regex_len = len(regex_lyrics.strip()) if regex_lyrics else 0

    if regex_lyrics and regex_len > extracted_len:
        if extracted_len == 0:
            logger.info("🔧 Lyrics not found by extraction model, using regex fallback: %d chars", regex_len)
        else:
            logger.info("🔧 Regex lyrics (%d chars) longer than extracted (%d chars), preferring regex", regex_len, extracted_len)
        params["lyrics"] = regex_lyrics
    elif extracted_len > 0:
        logger.info("🔧 Using extraction model lyrics: %d chars", extracted_len)

    # Deduplicate repetitive lyrics (common issue with extraction)
    if "lyrics" in params and params["lyrics"]:
        original_lyrics = params["lyrics"]
        # Split into lines and find repeated sections
        lines = original_lyrics.split('\n')
        seen_sections = []
        deduplicated_lines = []
        current_section = []

        for line in lines:
            stripped = line.strip()
            if not stripped:  # Empty line = section break
                if current_section:
                    section_text = '\n'.join(current_section)
                    # Only add if we haven't seen this exact section before
                    if section_text not in seen_sections:
                        seen_sections.append(section_text)
                        deduplicated_lines.extend(current_section)
                        deduplicated_lines.append('')  # Keep the blank line
                    current_section = []
            else:
                current_section.append(line)

        # Don't forget the last section
        if current_section:
            section_text = '\n'.join(current_section)
            if section_text not in seen_sections:
                deduplicated_lines.extend(current_section)

        deduplicated = '\n'.join(deduplicated_lines).strip()
        if len(deduplicated) < len(original_lyrics) * 0.8:  # Removed significant repetition
            params["lyrics"] = deduplicated
            logger.info("🔧 Removed repetitive lyrics: %d -> %d chars", len(original_lyrics), len(deduplicated))

    # FINAL SAFETY CHECK: One more validation before returning
    # This catches any edge cases that slipped through
    final_validation = _validate_extracted_params(params)
    if final_validation:
        logger.error("🚨 CRITICAL: Validation failed at final safety check!")
        logger.error("🚨 This should NEVER happen - validation was supposed to fix or reject earlier")
        for error in final_validation:
            logger.error("   - %s", error)
        raise ValueError(f"FINAL VALIDATION FAILED (this is a bug): {'; '.join(final_validation)}")

    lyrics_preview = params.get("lyrics", "")[:100] + "..." if params.get("lyrics") and len(params.get("lyrics", "")) > 100 else params.get("lyrics", "(none)")
    logger.info("🔧 The Engineer: Extraction complete - BPM=%s, Key=%s, Duration=%ss, Lyrics=%s",
                params.get("bpm", "auto"), params.get("key", "auto"), params.get("duration", 90), lyrics_preview)
    logger.debug("✅ Validated parameters: %s", params)

    # Unload extraction model immediately after extraction to free memory before ACE-Step
    if not use_chat_model_for_extraction:
        engineer_unload = unload_engineer_llm()
        logger.info("🧹 Extraction model unloaded after extraction: %s", engineer_unload.get("message", "done"))

    return params


def generate_track_name(track_metadata: Dict[str, Any]) -> Dict[str, Any]:
    """
    Generate a creative track name and genre based on track metadata using LLM.

    Args:
        track_metadata: Dict containing caption, lyrics, bpm, key, artist, genre, etc.

    Returns:
        Dict with 'track_name' and optional 'genre'
    """
    import json
    import re
    router = get_llm_router()

    # Build a descriptive prompt with all available metadata
    metadata_parts = []
    if caption := track_metadata.get("caption"):
        metadata_parts.append(f"Style/Description: {caption}")
    if lyrics := track_metadata.get("lyrics"):
        # Truncate lyrics if too long
        lyrics_preview = lyrics[:300] + "..." if len(lyrics) > 300 else lyrics
        metadata_parts.append(f"Lyrics:\n{lyrics_preview}")
    if bpm := track_metadata.get("bpm"):
        metadata_parts.append(f"BPM: {bpm}")
    if key := track_metadata.get("key"):
        metadata_parts.append(f"Key: {key}")
    if artist := track_metadata.get("artist"):
        metadata_parts.append(f"Artist: {artist}")
    if genre := track_metadata.get("genre"):
        metadata_parts.append(f"Genre: {genre}")

    metadata_text = "\n".join(metadata_parts)

    prompt = f"""Based on this track's metadata, suggest a creative, memorable track name AND a simple genre classification.

Track Metadata:
{metadata_text}

Respond with ONLY a JSON object in this format:
{{"track_name": "Your Creative Track Name", "genre": "Simple Genre"}}

Guidelines for track_name:
- Keep it concise (2-5 words typically)
- Make it memorable and catchy
- Reflect the mood, style, or key themes from the lyrics/description
- Avoid generic names like "Track 1" or "Untitled"
- If lyrics are provided, consider key phrases or themes

Guidelines for genre:
- Use a simple, standard genre label (1-3 words max)
- Examples: "Hip Hop", "Blues Rock", "Electro Pop", "Trip Hop / EDM", "Pop Punk", "Soul / R&B"
- Do NOT use the full style description as the genre
- Pick the most fitting primary genre

Respond with ONLY the JSON object, no other text."""

    messages = [
        {"role": "user", "content": prompt}
    ]

    try:
        result = router.chat(messages, temperature=0.5, max_tokens=100)
    except Exception:
        raise

    response_text = result.get("text", "") if isinstance(result, dict) else str(result)
    logger.debug("Track name generation response: %s", response_text)

    # Extract JSON from response
    json_match = re.search(r"\{[^{}]*\}", response_text)
    if not json_match:
        # Fallback: use the response text directly if no JSON found
        return {"track_name": response_text.strip().strip('"'), "genre": None}

    try:
        parsed = json.loads(json_match.group())
        track_name = parsed.get("track_name", "Untitled Track")
        genre = parsed.get("genre")
    except json.JSONDecodeError:
        track_name = response_text.split("\n")[0].strip().strip('"')
        genre = None

    logger.debug("Generated track name: %s, genre: %s", track_name, genre)
    return {"track_name": track_name, "genre": genre}


def _select_system_prompt(
    allow_auto_generation: bool,
    provider_type: Optional[ProviderType],
    model_name: Optional[str],
    agent_config: Optional[Dict[str, Any]] = None,
) -> str:
    base_prompt = SYSTEM_PROMPT_BASE
    tools_section = TOOLS_SECTION_AUTO if allow_auto_generation else TOOLS_SECTION_MANUAL
    tools_description = ", and you have the power to bring ideas to life using your music generation tools!" if allow_auto_generation else "."
    generation_hint = "Want me to generate that now?" if allow_auto_generation else "Let me know when you're ready to generate!"
    tool_reminder = "USE YOUR TOOLS to actually create music when asked!" if allow_auto_generation else "Help users refine their ideas - they'll use the 'Generate from Chat' button when ready"

    # Build base prompt
    prompt = base_prompt.format(
        tools_description=tools_description,
        generation_hint=generation_hint,
        tools_section=tools_section,
        tool_reminder=tool_reminder
    )

    if agent_config:
        custom_prompt = str(agent_config.get("system_prompt") or "").strip()
        custom_instructions = str(agent_config.get("custom_instructions") or "").strip()
        if custom_prompt:
            prompt = custom_prompt
        if custom_instructions:
            prompt += "\n\nADDITIONAL AGENT INSTRUCTIONS:\n" + custom_instructions

    # Add model-specific optimizations (custom prompt overrides take precedence)
    if model_name:
        model_specific_prompt = _get_custom_prompt_for_model(model_name) or get_model_system_prompt(model_name)
        if model_specific_prompt:
            prompt += "\n\n" + model_specific_prompt

    return prompt


def _agent_config_float(agent_config: Optional[Dict[str, Any]], key: str) -> Optional[float]:
    if not agent_config:
        return None
    value = agent_config.get(key)
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _agent_config_int(agent_config: Optional[Dict[str, Any]], key: str) -> Optional[int]:
    if not agent_config:
        return None
    value = agent_config.get(key)
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _agent_tool_ids(agent_config: Optional[Dict[str, Any]]) -> List[str]:
    if not agent_config:
        return [tool["name"] for tool in TOOL_DEFINITIONS]

    raw_value = agent_config.get("enabled_tool_ids", [])
    if not isinstance(raw_value, list):
        return []

    allowed = {tool["name"] for tool in TOOL_DEFINITIONS}
    return [str(item) for item in raw_value if str(item) in allowed]


def _get_custom_prompt_map() -> Dict[str, str]:
    global _custom_prompt_cache_raw, _custom_prompt_cache
    raw = os.getenv("MAJIK_CUSTOM_SYSTEM_PROMPTS_JSON", "").strip()
    if raw == _custom_prompt_cache_raw:
        return _custom_prompt_cache

    _custom_prompt_cache_raw = raw
    if not raw:
        _custom_prompt_cache = {}
        return _custom_prompt_cache

    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            _custom_prompt_cache = {
                str(k): str(v)
                for k, v in parsed.items()
                if isinstance(v, str) and str(v).strip()
            }
        else:
            _custom_prompt_cache = {}
    except Exception:
        _custom_prompt_cache = {}
    return _custom_prompt_cache


def _get_custom_prompt_for_model(model_name: Optional[str]) -> Optional[str]:
    if not model_name:
        return None
    prompts = _get_custom_prompt_map()
    prompt = prompts.get(model_name)
    if prompt and prompt.strip():
        return prompt
    return None


def _get_model_name_from_config(config, provider_type: ProviderType) -> str:
    mapping = {
        ProviderType.MLX_LOCAL: config.mlx_model,
        ProviderType.OPENROUTER: config.openrouter_model,
        ProviderType.ANTHROPIC: config.anthropic_model,
        ProviderType.OPENAI: config.openai_model,
        ProviderType.DEEPSEEK: config.deepseek_model,
        ProviderType.GEMINI: config.gemini_model,
        ProviderType.OLLAMA: config.openai_v1_model,
        ProviderType.LM_STUDIO: config.openai_v1_model,
        ProviderType.OPENAI_V1: config.openai_v1_model
    }
    return mapping.get(provider_type, "unknown")


def _resolve_chat_overrides(
    model_name: Optional[str],
    temperature_override: Optional[float],
    max_tokens_override: Optional[int],
    top_p_override: Optional[float],
) -> tuple[Optional[float], Optional[int], Optional[float]]:
    model_params = get_model_inference_params(model_name) if model_name else {}

    def _as_float(value: Any) -> Optional[float]:
        if value is None:
            return None
        try:
            return float(value)
        except (TypeError, ValueError):
            return None

    def _as_int(value: Any) -> Optional[int]:
        if value is None:
            return None
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    resolved_temperature = _as_float(temperature_override)
    if resolved_temperature is None:
        resolved_temperature = _as_float(model_params.get("temperature"))

    resolved_max_tokens = _as_int(max_tokens_override)
    if resolved_max_tokens is None:
        resolved_max_tokens = _as_int(model_params.get("max_tokens"))

    resolved_top_p = _as_float(top_p_override)
    if resolved_top_p is None:
        resolved_top_p = _as_float(model_params.get("top_p"))
    if resolved_top_p is None:
        resolved_top_p = 0.9

    return (resolved_temperature, resolved_max_tokens, resolved_top_p)


CAPTION_ENHANCEMENT_PROMPT = """You are a professional music producer helping enhance a track description.

The user provided this brief description: "{caption}"

Expand this into a rich, multi-dimensional caption that ACE-Step can use for high-quality music generation.

Include:
- Genre and sub-genre specifics
- Instrumentation (be detailed: "acoustic guitar fingerpicking", "808 bass", "vintage synthesizers")
- Mood and emotion (multiple dimensions if applicable)
- Energy level and tempo feel (even if BPM is specified separately)
- Production style (e.g., "lo-fi aesthetic", "crisp modern production", "analog warmth")
- Musical techniques or characteristics (e.g., "syncopated rhythm", "call and response", "crescendo")

Guidelines:
- Keep it 2-4 sentences, rich but concise
- Be specific and evocative
- Focus on musical characteristics the AI can interpret
- Don't mention artist names or copyrighted material

Respond with ONLY the enhanced caption text, no explanation, no quotes, no extra text."""


def enhance_caption(caption: str) -> str:
    """
    Enhance a simple caption into a rich, detailed description using LLM.

    Args:
        caption: Simple description from user (e.g., "upbeat electronic track")

    Returns:
        Enhanced multi-dimensional caption
    """
    router = get_llm_router()
    prompt = CAPTION_ENHANCEMENT_PROMPT.format(caption=caption)

    messages = [
        {"role": "user", "content": prompt}
    ]

    response = router.chat(messages=messages, tools=None)
    enhanced = response.get("text", response.get("content", "")).strip()

    # Clean up any markdown formatting or quotes
    enhanced = enhanced.strip('"\'`')
    if enhanced.startswith("```") and enhanced.endswith("```"):
        lines = enhanced.split("\n")
        enhanced = "\n".join(lines[1:-1]).strip()

    return enhanced
