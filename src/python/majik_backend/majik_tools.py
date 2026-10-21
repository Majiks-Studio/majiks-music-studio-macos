"""
Tool definitions for Majik to interact with the music studio
"""

from typing import Any, Dict, List, Optional

# Tool definitions for Claude API format
TOOL_DEFINITIONS = [
    {
        "name": "generate_music",
        "description": "Generate music based on a description. Creates 1-5 variants of the track with different parameters. Use this when the user asks to create, generate, or make music.",
        "input_schema": {
            "type": "object",
            "properties": {
                "caption": {
                    "type": "string",
                    "description": "Musical description including style, mood, instruments, tempo feel, etc. Be specific and creative."
                },
                "duration": {
                    "type": "integer",
                    "description": "Duration in seconds (30-180). Default 90.",
                    "minimum": 30,
                    "maximum": 180
                },
                "bpm": {
                    "type": "integer",
                    "description": "Beats per minute (60-200). Optional - omit to let the model choose based on style.",
                    "minimum": 60,
                    "maximum": 200
                },
                "key": {
                    "type": "string",
                    "description": "Musical key (e.g., 'C major', 'A minor'). Optional - omit to let the model choose."
                },
                "count": {
                    "type": "integer",
                    "description": "Number of variants to generate (1-5). Default 3.",
                    "minimum": 1,
                    "maximum": 5
                }
            },
            "required": ["caption"]
        }
    },
    {
        "name": "import_audio",
        "description": "Import an existing audio file (WAV, MP3, FLAC) into the studio for editing or as a reference.",
        "input_schema": {
            "type": "object",
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "Path to the audio file to import"
                }
            },
            "required": ["file_path"]
        }
    },
    {
        "name": "export_track",
        "description": "Export a generated track to a file in WAV, MP3, or FLAC format.",
        "input_schema": {
            "type": "object",
            "properties": {
                "track_id": {
                    "type": "string",
                    "description": "ID of the track to export (usually provided after generation)"
                },
                "format": {
                    "type": "string",
                    "enum": ["wav", "mp3", "flac"],
                    "description": "Output format. Default 'wav'."
                },
                "output_path": {
                    "type": "string",
                    "description": "Where to save the file. If not provided, uses a default location."
                }
            },
            "required": ["track_id"]
        }
    },
    {
        "name": "list_available_models",
        "description": "List all available music generation models and their capabilities.",
        "input_schema": {
            "type": "object",
            "properties": {}
        }
    }
]


def format_tools_for_provider(provider_type: str, allowed_tool_names: Optional[List[str]] = None) -> List[Dict[str, Any]]:
    """
    Format tool definitions based on LLM provider

    Different providers use different formats for tool calling.
    """
    tools_to_format = TOOL_DEFINITIONS
    if allowed_tool_names is not None:
        allowed = set(allowed_tool_names)
        tools_to_format = [tool for tool in TOOL_DEFINITIONS if tool["name"] in allowed]

    if provider_type in ["anthropic", "openrouter"]:
        # Claude API format (also supported by OpenRouter)
        return tools_to_format

    elif provider_type in ["openai", "openai_v1", "ollama", "lm_studio", "mlx_local"]:
        # OpenAI function calling format (also used by Qwen 3.5 chat templates)
        tools = []
        for tool in tools_to_format:
            tools.append({
                "type": "function",
                "function": {
                    "name": tool["name"],
                    "description": tool["description"],
                    "parameters": tool["input_schema"]
                }
            })
        return tools

    else:
        return []


def execute_tool(tool_name: str, tool_input: Dict[str, Any], generator) -> Dict[str, Any]:
    """
    Execute a tool call and return the result

    Args:
        tool_name: Name of the tool to execute
        tool_input: Input parameters for the tool
        generator: ACEGenerator instance for music operations

    Returns:
        Dictionary with success status and result/error
    """

    try:
        if tool_name == "generate_music":
            caption = tool_input["caption"]
            duration = tool_input.get("duration", 90)
            bpm = tool_input.get("bpm")
            key = tool_input.get("key")
            count = tool_input.get("count", 3)

            # Generate music
            import os
            import uuid

            track_id = str(uuid.uuid4())
            output_dir = f"./output/{track_id}"
            os.makedirs(output_dir, exist_ok=True)

            if count == 1:
                output_path = os.path.join(output_dir, "variant-1.wav")
                metadata = generator.generate_music(
                    caption=caption,
                    output_path=output_path,
                    duration=duration,
                    bpm=bpm,
                    key=key
                )
                return {
                    "success": True,
                    "track_id": track_id,
                    "variant_count": 1,
                    "duration": duration,
                    "bpm": metadata.get("bpm", bpm),
                    "key": metadata.get("key", key),
                    "file_path": output_path
                }
            else:
                variants = generator.generate_variants(
                    caption=caption,
                    output_dir=output_dir,
                    count=count,
                    duration=duration,
                    bpm=bpm,
                    key=key
                )
                return {
                    "success": True,
                    "track_id": track_id,
                    "variant_count": len(variants),
                    "variants": [
                        {
                            "file_path": v.get("file_path"),
                            "bpm": v.get("bpm"),
                            "key": v.get("key")
                        }
                        for v in variants
                    ]
                }

        elif tool_name == "import_audio":
            file_path = tool_input["file_path"]
            output_dir = "./output/imported"

            metadata = generator.import_audio(file_path, output_dir)

            return {
                "success": True,
                "imported": True,
                "metadata": metadata
            }

        elif tool_name == "export_track":
            track_id = tool_input["track_id"]
            format_name = tool_input.get("format", "wav")
            output_path = tool_input.get("output_path", f"./output/export_{track_id}.{format_name}")

            # Find the track file
            source_path = f"./output/{track_id}/variant-1.wav"

            result = generator.export_track(source_path, output_path, format_name)

            return {
                "success": True,
                "exported_path": result.get("exported_path"),
                "format": format_name
            }

        elif tool_name == "list_available_models":
            models = generator.list_models()

            return {
                "success": True,
                "models": models
            }

        else:
            return {
                "success": False,
                "error": f"Unknown tool: {tool_name}"
            }

    except Exception as e:
        return {
            "success": False,
            "error": str(e)
        }
