"""
Model-Specific Configurations for Majiks Studio

Each model has unique requirements for optimal performance:
- System prompt additions (harmony format, reasoning levels, etc.)
- Inference parameters (temperature, max_tokens, context window)
- Special handling (response parsing, format requirements)

This module provides model-specific optimizations automatically applied by the backend.
"""

from typing import Dict, Any, Optional


# Model-specific system prompt additions
MODEL_SYSTEM_PROMPTS: Dict[str, str] = {
    "mlx-community/gpt-oss-20b-MXFP4-Q8": """
**RESPONSE FORMAT (CRITICAL):**
You MUST use the OpenAI Harmony response format. Structure your responses as:

<|channel|>analysis<|message|>
[Your internal chain-of-thought reasoning - analysis of the user's request]
<|end|>

<|channel|>final<|message|>
[Your actual response to the user - the message they will see]
<|end|>

**IMPORTANT:** Use 'analysis' channel for thinking, 'final' channel for user response.

**REASONING LEVELS:**
This model supports adaptive reasoning. For music production questions:
- Simple questions (genre recommendations, BPM suggestions): Use low reasoning
- Creative tasks (lyrics, arrangements): Use medium reasoning
- Complex production/theory questions: Use high reasoning

**HARMONY FORMAT EXAMPLE:**
<|channel|>analysis<|message|>
User wants a chill lo-fi beat for studying. I should suggest 75-85 BPM, warm instruments like Rhodes piano, and ambient textures. Keep it mellow and not distracting.
<|end|>

<|channel|>final<|message|>
I'll create a perfect study vibe for you! 🎵 I'm thinking 80 BPM lo-fi hip hop with:
- Warm Rhodes piano chords
- Soft vinyl crackle texture
- Mellow kick and snare
- Ambient rain sounds
- C minor key for that contemplative mood

Want me to generate this?
<|end|>
""",

    "mlx-community/granite-4.0-h-micro-4bit": """
**GRANITE H-MICRO EXECUTION MODE (CRITICAL):**
When asked to write lyrics, write them immediately. Do NOT announce intent first.

GOOD:
User: "Write a verse about summer"
You:
**Verse:**
Golden rays painting the sky
Barefoot dancing, we don't ask why
...

BAD:
"I'm going to write you a verse about summer!"

**MUSIC ASSISTANT RULES:**
- Deliver complete outputs, not previews (full verse/chorus/bridge when requested)
- Give concrete production guidance (BPM, key, arrangement, instrumentation, mix ideas)
- If the user asks to create or generate music and tools are available, use `generate_music`
- Prioritize action over meta commentary

**MODEL NOTE:**
You're a compact 3B model. If a long output is requested, still start delivering immediately and continue in clear sections.
""",

    "lmstudio-community/granite-4.0-h-small-MLX-4bit": """
**CREATIVE POWERHOUSE:**
You're running on Granite 4.0 H-Small - a 9B hybrid MoE model excellent for creative tasks. Use your strengths:
- Rich, detailed lyrics and creative writing
- Nuanced musical suggestions
- Function calling for music generation

Strike a balance between detail and practicality.
""",

    "mlx-community/granite-3.3-8b-instruct-4bit": """
**FUNCTION CALLING:**
You support function calling capabilities. Use the generate_music tool proactively when users want to create music.

Keep responses practical and focused on actionable music production advice.
""",

    "mlx-community/GLM-4.7-Flash-4bit": """
**MULTILINGUAL & FAST:**
You're running on GLM-4.7 Flash - optimized for speed (60-80 tok/s) and multilingual support.
- Respond in the user's language
- Keep responses snappy but informative
- Use creative flair for lyrics and descriptions
""",

    "mistral-large-latest": """
**MISTRAL LARGE MUSIC MODE:**
You are an expert music producer and songwriter. Deliver complete outputs, not partial examples.
- When asked for lyrics, provide full sections immediately (verse/chorus/bridge as requested)
- Be specific with arrangement and production details
- When user intent is to create music, suggest using `generate_music` with concrete parameters
Leverage your strong reasoning for nuanced genre blending and structural polish.
""",

    "mistral-medium-latest": """
**MISTRAL MEDIUM MUSIC MODE:**
Focus on practical, complete music creation help.
- Write full lyrics immediately when requested
- Keep production suggestions actionable and clear
- Proactively suggest `generate_music` when the concept is sufficiently detailed
Balance creativity with concise execution.
""",

    "mistral-small-latest": """
**MISTRAL SMALL MUSIC MODE:**
Be direct and action-oriented.
- If asked for lyrics, write them immediately in complete sections
- Avoid saying what you will do; just do it
- Provide short, specific production guidance
- Recommend `generate_music` when users ask to create tracks
""",

    "deepseek-chat": """
**DEEPSEEK CHAT MUSIC MODE:**
You are a music production copilot.
- Deliver complete lyrics and structured song sections on request
- Provide concrete BPM/key/instrumentation recommendations
- Use concise but practical explanations
- Suggest `generate_music` when user asks to make/create a track
""",

    "deepseek-coder": """
**DEEPSEEK CODER MUSIC-TECH MODE:**
You are strong at technical precision. Apply it to music workflows.
- Provide complete lyric outputs when requested, not templates
- Give structured, implementation-ready production plans
- Recommend `generate_music` with explicit parameters when the user wants audio output
Use your strength for structured arrangements, cue sheets, and repeatable workflows.
""",

    "gpt-4o": """
**GPT-4O MUSIC PRODUCER MODE:**
Act as an expert producer-songwriter.
- Write complete lyrics immediately when asked
- Give detailed but usable production direction (BPM, key, instrumentation, mix)
- When user asks to create/generate music, propose or call `generate_music` with concrete parameters
Use your multimodal and reasoning strengths for polished, coherent musical direction.
""",

    "gpt-4-turbo": """
**GPT-4 TURBO MUSIC MODE:**
Prioritize fast, complete delivery for music creation tasks.
- Full lyrics on request, no placeholder examples
- Strong arrangement and songwriting structure support
- Suggest `generate_music` when intent is generation
Use your long-context strength to maintain consistency across the full conversation.
""",

    "gpt-3.5-turbo": """
**GPT-3.5 MUSIC ASSIST MODE:**
Be concise, clear, and action-first.
- Write requested lyrics directly and completely
- Keep production advice practical and specific
- Suggest `generate_music` when user intent is to create tracks
Avoid meta commentary and keep outputs immediately usable.
""",

    "claude-3-5-sonnet-20241022": """
**CLAUDE 3.5 SONNET MUSIC MODE:**
Use your strong writing and reasoning to deliver production-ready results.
- Write complete lyrics immediately when asked
- Provide specific musical direction with emotional and technical detail
- Recommend `generate_music` when user asks to make/create music
Optimize for clarity, creativity, and end-to-end usefulness.
""",

    "claude-3-opus-20240229": """
**CLAUDE 3 OPUS MUSIC MODE:**
Deliver high-quality, fully formed creative outputs.
- Full lyric sections immediately (no preamble)
- Deep arrangement and songwriting guidance
- Suggest `generate_music` for actionable generation steps
Use your strengths for nuanced storytelling, hooks, and polished structure.
""",

    "claude-3-haiku-20240307": """
**CLAUDE 3 HAIKU MUSIC MODE:**
Be fast, direct, and practical.
- Output complete lyrics immediately when requested
- Keep suggestions concise and concrete
- Recommend `generate_music` when user intent is generation
Favor quick, high-utility responses.
""",

    # Qwen3 MoE Models (MLX)
    "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit": """
**QWEN3-CODER 30B MoE MUSIC MODE:**
You're a powerful MoE model (30B params, 3B active) optimized for structured thinking.
- Write complete lyrics immediately when requested, with strong narrative structure
- Apply your coding/structure strength to song arrangement (verse/chorus/bridge flow)
- Give detailed production guidance with technical precision
- Suggest `generate_music` when user intent is clear
CRITICAL: Avoid repetitive loops - vary your phrasing and word choices (your top_p is set high for this).
""",

    "lmstudio-community/Qwen3-30B-A3B-Instruct-MLX-4bit": """
**QWEN3 30B MoE MUSIC MODE:**
You're a fast, efficient MoE model optimized for balanced inference.
- Deliver complete creative outputs (full lyrics sections when requested)
- Provide detailed musical direction with clear structure
- Recommend `generate_music` when appropriate
- Avoid repetition - use your strong vocabulary to keep outputs fresh
Leverage your efficiency (3B active params) for quick, quality responses.
""",

    "mlx-community/Qwen3-30B-A3B-Thinking-2507-4bit": """
**QWEN3 THINKING MODE (MUSIC PRODUCTION):**
You have thinking mode enabled (like QwQ-32B) - use it strategically for creative tasks.
- For complex lyric writing: Engage thinking mode to craft cohesive narrative, strong hooks, varied vocabulary
- For parameter extraction: Use thinking to ensure accuracy (correct BPM, key, emotional tone)
- For production advice: Reason through arrangement, mixing, genre conventions
- Then deliver the FINAL RESULT immediately (no meta-commentary)

CRITICAL:
- After thinking, output the complete creative work (full verse/chorus/bridge when requested)
- Avoid repetitive phrasing - your thinking mode helps you find fresh expressions
- Recommend `generate_music` when user wants to create tracks

Your strength: Deep reasoning + strong creative output. Use both.
""",

    # Qwen3.5 Models (MLX)
    "mlx-community/Qwen3.5-4B-4bit": """/no_think
**QWEN 3.5 4B MUSIC MODE:**
You're a compact but capable music production assistant.
- Write complete lyrics immediately when requested
- Give specific BPM, key, and instrumentation advice
- Recommend `generate_music` when user wants to create tracks
- Be direct and actionable — avoid excessive preamble
- Do NOT output any thinking or reasoning blocks — respond directly
""",

    "mlx-community/Qwen3.5-9B-4bit": """/no_think
**QWEN 3.5 9B MUSIC MODE:**
You're a powerful music production assistant with strong reasoning capabilities.
- Write complete, polished lyrics immediately when requested
- Provide detailed production guidance with technical and emotional depth
- Recommend `generate_music` when user intent is clear
- Balance creativity with precision
- Do NOT output any thinking or reasoning blocks — respond directly

**TOOL CALLING FORMAT (CRITICAL):**
When you decide to call a tool, you MUST output it in this exact format:
<tool_call>
{"name": "tool_name", "arguments": {"param1": "value1", "param2": "value2"}}
</tool_call>

For example, to generate music:
<tool_call>
{"name": "generate_music", "arguments": {"caption": "chill lo-fi hip hop beat with mellow piano", "duration": 120}}
</tool_call>

Do NOT describe tool calls in natural language. Use the <tool_call> XML tags.
""",

    # Llama Models (MLX)
    "mlx-community/Llama-3.3-70B-Instruct-4bit": """
**LLAMA 3.3 70B MUSIC MODE:**
You're Meta's flagship open model with excellent reasoning and tool calling.
- Write complete lyrics immediately when requested (no announcements)
- Use your tool-calling strength to suggest `generate_music` proactively
- Provide nuanced production guidance with emotional and technical depth
- Leverage your 128K context to maintain consistency across long creative sessions
Strong at structured thinking - use it for song arrangement and lyrical coherence.
""",

    "mlx-community/Meta-Llama-3.1-70B-Instruct-4bit": """
**LLAMA 3.1 70B MUSIC MODE:**
Deliver high-quality, structured music production help.
- Output complete lyrics directly when asked
- Strong reasoning for arrangement, harmony, and song structure
- Recommend `generate_music` when user wants to create tracks
Use your context window to remember all details from the conversation.
""",

    "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit": """
**LLAMA 3.1 8B MUSIC MODE:**
Be efficient and practical.
- Write complete lyrics immediately (no preamble)
- Keep production suggestions concrete and actionable
- Suggest `generate_music` when appropriate
Balance quality with speed - you're optimized for fast, useful responses.
""",

    "mlx-community/Llama-3.2-3B-Instruct-4bit": """
**LLAMA 3.2 3B MUSIC MODE (OPTIMIZED FOR CREATIVE QUALITY):**
You're a compact but powerful creative assistant - Meta's newest small model.

**YOUR STRENGTHS (17/18 test score!):**
- Excellent lyric writing with varied vocabulary
- Low repetition, emotionally compelling output
- Clear, actionable production advice

**MUSIC ASSISTANT GUIDELINES:**
- Write complete lyrics immediately when requested (verse/chorus/bridge)
- Use varied, evocative language - avoid repetitive phrasing
- Give specific production advice (BPM ranges, key suggestions, techniques)
- Recommend `generate_music` when user wants to create tracks

**IMPORTANT:** Parameter extraction is handled by The Engineer (separate model).
Your job is CREATIVE QUALITY - compelling lyrics, helpful advice, engaging conversation.

Focus on emotional depth and practical usefulness.
""",
}


# Model-specific inference parameters
MODEL_INFERENCE_PARAMS: Dict[str, Dict[str, Any]] = {
    "mlx-community/gpt-oss-20b-MXFP4-Q8": {
        "temperature": 0.7,          # Balanced creativity and coherence
        "max_tokens": 2048,           # Longer responses for detailed reasoning
        "top_p": 0.9,
        "reasoning_level": "high",    # Enable deep reasoning
        "uses_harmony_format": True,  # Requires special response parsing
        "context_window": 8192,       # Supports long conversations
    },

    "mlx-community/granite-4.0-h-micro-4bit": {
        "temperature": 0.2,           # IBM recommends temp=0 for Granite 4; 0.2 adds slight creativity
        "max_tokens": 2000,           # Comfortable headroom for lyrics + explanations + production advice
        "top_p": 0.9,                 # Slightly higher sampling for varied creative responses
        "context_window": 131072,     # 128K context (massive!)
        "supports_tools": True,       # Excellent tool-calling capabilities
    },

    "lmstudio-community/granite-4.0-h-small-MLX-4bit": {
        "temperature": 0.7,           # Good for creative writing
        "max_tokens": 1500,
        "top_p": 0.9,
        "context_window": 131072,     # 128K context
        "supports_tools": True,
    },

    "mlx-community/granite-3.3-8b-instruct-4bit": {
        "temperature": 0.6,           # More deterministic
        "max_tokens": 4000,           # Can handle longer responses
        "top_p": 0.85,
        "context_window": 131072,     # 128K context
        "supports_tools": True,
    },

    "mlx-community/GLM-4.7-Flash-4bit": {
        "temperature": 0.9,           # Higher for creative multilingual responses
        "max_tokens": 2500,
        "top_p": 0.92,
        "reasoning_level": "medium",
        "context_window": 131072,
        "supports_tools": True,
    },

    # Mistral
    "mistral-large-latest": {
        "temperature": 0.7,
        "max_tokens": 2200,
        "top_p": 0.9,
        "context_window": 128000,
        "supports_tools": True,
    },
    "mistral-medium-latest": {
        "temperature": 0.7,
        "max_tokens": 1800,
        "top_p": 0.9,
        "context_window": 32000,
        "supports_tools": True,
    },
    "mistral-small-latest": {
        "temperature": 0.65,
        "max_tokens": 1400,
        "top_p": 0.9,
        "context_window": 32000,
        "supports_tools": True,
    },

    # DeepSeek
    "deepseek-chat": {
        "temperature": 0.65,
        "max_tokens": 2000,
        "top_p": 0.9,
        "context_window": 64000,
        "supports_tools": False,
    },
    "deepseek-coder": {
        "temperature": 0.55,
        "max_tokens": 1800,
        "top_p": 0.9,
        "context_window": 64000,
        "supports_tools": False,
    },

    # OpenAI
    "gpt-4o": {
        "temperature": 0.7,
        "max_tokens": 2000,
        "top_p": 0.9,
        "context_window": 128000,
        "supports_tools": True,
    },
    "gpt-4-turbo": {
        "temperature": 0.7,
        "max_tokens": 1800,
        "top_p": 0.9,
        "context_window": 128000,
        "supports_tools": True,
    },
    "gpt-3.5-turbo": {
        "temperature": 0.75,
        "max_tokens": 1400,
        "top_p": 0.9,
        "context_window": 16000,
        "supports_tools": True,
    },

    # Anthropic
    "claude-3-5-sonnet-20241022": {
        "temperature": 0.65,
        "max_tokens": 2200,
        "top_p": 0.9,
        "context_window": 200000,
        "supports_tools": False,
    },
    "claude-3-opus-20240229": {
        "temperature": 0.7,
        "max_tokens": 2400,
        "top_p": 0.9,
        "context_window": 200000,
        "supports_tools": False,
    },
    "claude-3-haiku-20240307": {
        "temperature": 0.65,
        "max_tokens": 1600,
        "top_p": 0.9,
        "context_window": 200000,
        "supports_tools": False,
    },

    # Qwen3 MoE Models (MLX) - Official Qwen3 recommendations
    "lmstudio-community/Qwen3-Coder-30B-A3B-Instruct-MLX-4bit": {
        "temperature": 0.7,           # Qwen3 official: 0.7 for dialogue
        "max_tokens": 2200,           # Sufficient for complete lyrics + production advice
        "top_p": 0.8,                 # Qwen3 official: 0.8 for dialogue (NOT 0.95 - that's for reasoning)
        "top_k": 20,                  # Qwen3 official recommendation
        "context_window": 32768,      # 32K context
        "supports_tools": True,       # Excellent tool calling
    },
    "lmstudio-community/Qwen3-30B-A3B-Instruct-MLX-4bit": {
        "temperature": 0.7,           # Qwen3 official: 0.7 for dialogue
        "max_tokens": 2200,
        "top_p": 0.8,                 # Qwen3 official: 0.8 for dialogue
        "top_k": 20,
        "context_window": 32768,
        "supports_tools": True,
    },

    "mlx-community/Qwen3-30B-A3B-Thinking-2507-4bit": {
        "temperature": 0.7,           # Qwen3 official: 0.7 for dialogue
        "max_tokens": 3000,           # Higher for thinking mode outputs
        "top_p": 0.8,                 # Qwen3 official: 0.8 for dialogue
        "top_k": 20,
        "context_window": 32768,
        "supports_tools": True,
        "thinking_mode": True,        # Flag to indicate thinking capabilities
    },

    # Qwen3.5 Models (MLX)
    "mlx-community/Qwen3.5-4B-4bit": {
        "temperature": 0.0,           # Deterministic for extraction
        "max_tokens": 2000,           # JSON + lyrics
        "top_p": 0.8,                 # Qwen3 recommendation
        "context_window": 32768,      # 32K context
        "supports_tools": True,       # Qwen 3.5 has native tool calling via chat template
    },
    "mlx-community/Qwen3.5-9B-4bit": {
        "temperature": 0.7,
        "max_tokens": 2200,
        "top_p": 0.8,
        "context_window": 32768,
        "supports_tools": True,
    },

    # Llama Models (MLX)
    "mlx-community/Llama-3.3-70B-Instruct-4bit": {
        "temperature": 0.7,           # Balanced for creative + technical
        "max_tokens": 2400,           # Full lyrics + explanations
        "top_p": 0.9,
        "context_window": 131072,     # 128K context
        "supports_tools": True,       # Llama 3.3 supports function calling
    },
    "mlx-community/Meta-Llama-3.1-70B-Instruct-4bit": {
        "temperature": 0.7,
        "max_tokens": 2200,
        "top_p": 0.9,
        "context_window": 131072,     # 128K context
        "supports_tools": True,       # Llama 3.1 supports function calling
    },
    "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit": {
        "temperature": 0.7,
        "max_tokens": 1800,
        "top_p": 0.9,
        "context_window": 131072,     # 128K context
        "supports_tools": True,
    },
    "mlx-community/Llama-3.2-3B-Instruct-4bit": {
        "temperature": 0.7,
        "max_tokens": 1600,           # Smaller model, shorter context
        "top_p": 0.9,
        "context_window": 131072,     # Still 128K!
        "supports_tools": False,      # 3B model - less reliable for tools
    },
    # NuExtract - The Engineer's extraction model
    # Based on Phi-3-mini with 4K context - MUST truncate long conversations
    "mlx-community/numind-NuExtract-1.5-MLX-4bit": {
        "temperature": 0.0,           # Deterministic for reliable JSON
        "max_tokens": 800,            # JSON output is compact
        "top_p": 0.9,
        "context_window": 4096,       # Phi-3-mini base = 4K context ONLY
        "supports_tools": False,
        "max_input_chars": 8000,      # ~2K tokens for input, leave room for output
    },
}


# Bundled model detection paths
# Models are bundled at Contents/Resources/mlx-models/mlx-community/<model-name>
# Path is relative to majik_backend/ directory (one level up from model_configs.py)
BUNDLED_MODEL_PATHS = {
    "mlx-community/gpt-oss-20b-MXFP4-Q8": [
        "../mlx-models/mlx-community/gpt-oss-20b-MXFP4-Q8",  # Relative to majik_backend/
        "../../mlx-models/mlx-community/gpt-oss-20b-MXFP4-Q8",  # Alternative (app bundle)
        # Development path: from src/python/majik_backend/ to dist/.../mlx-models/
        "../../../dist/Majiks Music Studio.app/Contents/Resources/mlx-models/mlx-community/gpt-oss-20b-MXFP4-Q8",
    ],
    "mlx-community/granite-4.0-h-micro-4bit": [
        "../mlx-models/mlx-community/granite-4.0-h-micro-4bit",
        "../../mlx-models/mlx-community/granite-4.0-h-micro-4bit",
        # Development path: from src/python/majik_backend/ to dist/.../mlx-models/
        "../../../dist/Majiks Music Studio.app/Contents/Resources/mlx-models/mlx-community/granite-4.0-h-micro-4bit",
    ],
    "lmstudio-community/granite-4.0-h-small-MLX-4bit": [
        "../mlx-models/mlx-community/granite-4.0-h-small-MLX-4bit",
        "../../mlx-models/mlx-community/granite-4.0-h-small-MLX-4bit",
        "../../../dist/Majiks Music Studio.app/Contents/Resources/mlx-models/mlx-community/granite-4.0-h-small-MLX-4bit",
    ],
    "mlx-community/Llama-3.2-3B-Instruct-4bit": [
        "../mlx-models/mlx-community/Llama-3.2-3B-Instruct-4bit",
        "../../mlx-models/mlx-community/Llama-3.2-3B-Instruct-4bit",
        "../../../dist/Majiks Music Studio.app/Contents/Resources/mlx-models/mlx-community/Llama-3.2-3B-Instruct-4bit",
    ],
    "mlx-community/numind-NuExtract-1.5-MLX-4bit": [
        "../mlx-models/mlx-community/numind-NuExtract-1.5-MLX-4bit",
        "../../mlx-models/mlx-community/numind-NuExtract-1.5-MLX-4bit",
        "../../../dist/Majiks Music Studio.app/Contents/Resources/mlx-models/mlx-community/numind-NuExtract-1.5-MLX-4bit",
    ],
    "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit": [
        "../mlx-models/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
        "../../mlx-models/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
        "../../../dist/Majiks Music Studio.app/Contents/Resources/mlx-models/mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
    ],
}


def get_model_system_prompt(model_name: str) -> str:
    """Get model-specific system prompt addition (empty string if none)"""
    return MODEL_SYSTEM_PROMPTS.get(model_name, "")


def get_model_inference_params(model_name: str) -> Dict[str, Any]:
    """Get model-specific inference parameters"""
    return MODEL_INFERENCE_PARAMS.get(model_name, {})


def get_bundled_model_paths(model_name: str) -> list:
    """Get possible bundled model paths for a given model"""
    return BUNDLED_MODEL_PATHS.get(model_name, [])


def is_model_bundled(model_name: str) -> bool:
    """Check if a model is bundled in the app"""
    import os
    from pathlib import Path

    # Get the backend location
    backend_dir = Path(__file__).parent.absolute()

    # Check all possible bundled paths
    for relative_path in get_bundled_model_paths(model_name):
        check_path = backend_dir / relative_path
        if check_path.exists() and check_path.is_dir():
            # Check for direct model files (flat structure)
            model_files = list(check_path.glob("*.safetensors")) + \
                          list(check_path.glob("*.npz")) + \
                          list(check_path.glob("config.json"))
            if model_files:
                return True

            # Check for HuggingFace cache format (snapshots/ directory)
            snapshots_dir = check_path / "snapshots"
            if snapshots_dir.exists() and snapshots_dir.is_dir():
                # Valid HF cache directory
                return True

    return False


def get_bundled_model_path(model_name: str) -> Optional[str]:
    """Get the absolute path to a bundled model if it exists"""
    import os
    from pathlib import Path

    backend_dir = Path(__file__).parent.absolute()

    for relative_path in get_bundled_model_paths(model_name):
        check_path = backend_dir / relative_path
        if check_path.exists() and check_path.is_dir():
            # Check for direct model files (flat structure)
            model_files = list(check_path.glob("*.safetensors")) + \
                          list(check_path.glob("*.npz")) + \
                          list(check_path.glob("config.json"))
            if model_files:
                return str(check_path.absolute())

            # Check for HuggingFace cache format (snapshots/ directory)
            snapshots_dir = check_path / "snapshots"
            refs_main = check_path / "refs" / "main"

            if snapshots_dir.exists() and snapshots_dir.is_dir():
                # Read the snapshot hash from refs/main
                if refs_main.exists():
                    try:
                        snapshot_hash = refs_main.read_text().strip()
                        snapshot_path = snapshots_dir / snapshot_hash
                        if snapshot_path.exists() and snapshot_path.is_dir():
                            # Return the actual snapshot directory with model files
                            return str(snapshot_path.absolute())
                    except Exception:
                        pass

                # Fallback: find any snapshot directory
                snapshot_dirs = list(snapshots_dir.iterdir())
                if snapshot_dirs:
                    return str(snapshot_dirs[0].absolute())

    return None


# Model-specific response post-processing
def process_model_response(model_name: str, response: str) -> str:
    """
    Apply model-specific response processing

    For gpt-oss-20b: Parse harmony format and extract 'final' channel
    For others: Return as-is
    """
    params = get_model_inference_params(model_name)

    if params.get("uses_harmony_format"):
        import re
        # Extract 'final' channel from harmony format
        final_pattern = r'<\|channel\|>final<\|message\|>(.*?)(?:<\|end\||$)'
        match = re.search(final_pattern, response, re.DOTALL)
        if match:
            return match.group(1).strip()

    return response.strip()


# ============================================================================
# THE ENGINEER - Parameter Extraction Agent
# ============================================================================

# Default extraction model for The Engineer
# Qwen 3.5 4B 4-bit: Fast, accurate structured extraction with 32K context
# Strong instruction following for JSON extraction with minimal hallucination
DEFAULT_EXTRACTION_MODEL = "mlx-community/Qwen3.5-4B-4bit"

# The Engineer's system prompt — field descriptions in system prompt work best with Qwen 3.5 4B
ENGINEER_SYSTEM_PROMPT = """You are a precise JSON extraction assistant. Extract music parameters from a conversation between a user and a songwriting assistant. Output ONLY a JSON object with these fields:

- "caption": string describing the music style, genre, instruments, and mood.
  IMPORTANT: The genre and style MUST come from what the USER requested, NOT from the assistant's interpretation.
  If the user said "swing" but the assistant wrote a synthwave song, the caption must say "swing".
  Use the user's MOST RECENT style/genre preferences — they may have refined their request during the conversation.
  Add instrument and mood details from the discussion, but always anchor to the user's genre.

- "duration": number in seconds (convert minutes to seconds: "3 minutes" = 180, "2.5 minutes" = 150, "2:30" = 150, "90 seconds" = 90). Always output seconds as a number.
  CRITICAL: Use the duration that the USER explicitly requested, NOT a duration the assistant suggested or assumed.
  If the user said "make it 2 minutes" but the assistant responded with "Duration: 3 minutes", output 120 (the user's request).
  If the user never specified a duration, use the assistant's suggestion. Prefer the MOST RECENT user request if they changed it.

- "bpm": integer beats per minute. Only include if the user explicitly mentioned a BPM. Use their MOST RECENT value.

- "key": string musical key (e.g. "Bb major", "A minor"). Only include if the user explicitly mentioned a key. Use their MOST RECENT value.

- "lyrics": string with the complete song lyrics from the conversation, using \\n for line breaks.
  Include ONLY actual lyrics (verses, chorus, bridge, outro).
  Do NOT include arrangement notes, production ideas, commentary, or explanations.
  Use the MOST RECENT version of the lyrics if the user asked for changes.

Output ONLY valid JSON. No markdown. No explanation."""

# The Engineer's inference parameters (optimized for extraction)
ENGINEER_INFERENCE_PARAMS = {
    "temperature": 0.0,        # Zero temp for maximum determinism
    "max_tokens": 2000,        # Sufficient for JSON + lyrics
    "top_p": 0.9,
    "skip_harmony_parsing": True,  # Engineer outputs pure JSON
}


# Export all functions
__all__ = [
    'MODEL_SYSTEM_PROMPTS',
    'MODEL_INFERENCE_PARAMS',
    'BUNDLED_MODEL_PATHS',
    'DEFAULT_EXTRACTION_MODEL',
    'ENGINEER_SYSTEM_PROMPT',
    'ENGINEER_INFERENCE_PARAMS',
    'GENRE_TEMPLATES',
    'get_model_system_prompt',
    'get_model_inference_params',
    'get_bundled_model_paths',
    'is_model_bundled',
    'get_bundled_model_path',
    'process_model_response',
]


# ── Genre Templates for Variation Generation ─────────────────────
# Maps genre name (lowercase) to default ACE-Step tags and BPM range.
GENRE_TEMPLATES: Dict[str, Dict[str, Any]] = {
    "pop": {"tags": "catchy pop, polished vocals, bright synths, radio-friendly", "bpm_range": (100, 130)},
    "rock": {"tags": "driving rock, electric guitars, powerful drums, distortion", "bpm_range": (110, 140)},
    "hip hop": {"tags": "hip hop beats, 808 bass, trap hi-hats, rap vocals", "bpm_range": (80, 100)},
    "rap": {"tags": "aggressive rap, hard-hitting 808s, punchy snares", "bpm_range": (70, 95)},
    "trap": {"tags": "dark trap, rolling hi-hats, heavy 808 bass, atmospheric", "bpm_range": (130, 165)},
    "edm": {"tags": "electronic dance music, synth drops, four-on-the-floor, euphoric", "bpm_range": (125, 140)},
    "jazz": {"tags": "jazz, smooth saxophone, walking bass, brushed drums, swing feel", "bpm_range": (90, 160)},
    "blues": {"tags": "blues, soulful guitar, shuffle rhythm, minor pentatonic", "bpm_range": (70, 120)},
    "country": {"tags": "country, acoustic guitar, steel guitar, fiddle, heartfelt vocals", "bpm_range": (90, 130)},
    "folk": {"tags": "folk, acoustic guitar, gentle vocals, storytelling", "bpm_range": (80, 120)},
    "reggae": {"tags": "reggae, offbeat rhythm, bass-heavy, laid-back groove", "bpm_range": (70, 90)},
    "soul": {"tags": "soul, warm vocals, rich harmonies, motown groove", "bpm_range": (85, 110)},
    "r&b": {"tags": "R&B, smooth vocals, neo-soul, lush pads", "bpm_range": (70, 100)},
    "funk": {"tags": "funk, slap bass, rhythmic guitar, tight groove, brass stabs", "bpm_range": (100, 120)},
    "metal": {"tags": "heavy metal, distorted guitars, double kick drums, aggressive vocals", "bpm_range": (120, 180)},
    "punk": {"tags": "punk rock, fast tempo, power chords, raw energy", "bpm_range": (160, 200)},
    "classical": {"tags": "orchestral, strings, woodwinds, dynamic, cinematic", "bpm_range": (60, 140)},
    "ambient": {"tags": "ambient, atmospheric pads, ethereal textures, spacious reverb", "bpm_range": (60, 90)},
    "lo-fi": {"tags": "lo-fi hip hop, dusty samples, vinyl crackle, chill beats", "bpm_range": (70, 90)},
    "synthwave": {"tags": "synthwave, retro synths, analog warmth, 80s nostalgia, driving bass", "bpm_range": (100, 130)},
    "ballad": {"tags": "emotional ballad, piano, gentle strings, intimate vocals", "bpm_range": (60, 80)},
    "latin": {"tags": "latin, reggaeton, dembow rhythm, tropical, percussion", "bpm_range": (88, 100)},
    "afrobeats": {"tags": "afrobeats, percussion-driven, infectious groove, West African influence", "bpm_range": (100, 115)},
    "drill": {"tags": "drill, dark slides, aggressive 808s, bouncy rhythm", "bpm_range": (140, 145)},
    "boom bap": {"tags": "boom bap, classic hip hop, chopped samples, dusty drums", "bpm_range": (85, 100)},
    "indie rock": {"tags": "indie rock, jangly guitars, lo-fi aesthetic, alternative", "bpm_range": (110, 140)},
}
