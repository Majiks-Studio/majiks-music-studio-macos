"""MCP (Model Context Protocol) server for Majik's Music Studio.

Exposes music generation, library management, export, publishing, and AI chat tools
so external AI agents (Claude Code, Claude Desktop, etc.) can automate the full
songwriting → generation → artwork → publishing pipeline.

Usage:
    python -m majik_backend.mcp_server
    # Or via the 'majiks-music-studio-mcp' entry point

NOTE (L6, 2026-07): the app-level engine MCP server (Rust rmcp, the
`engine/agent-surface` crate, localhost port 8478) is the going-forward SINGLE
endpoint for the Studio DAW, so agents configure one server. This stdio server
keeps working for library / publish / gen and is not removed; it deprecates
after P2 tool parity, and that will be announced in release notes, not silently.
"""

import json
import sys
from typing import Any

from mcp.server import Server
from mcp.types import Resource, TextContent, Tool

from .rpc_server import handle_request

app = Server("majiks-music-studio")


# ── Helpers ───────────────────────────────────────────────────────

def _json_result(data: Any) -> list[TextContent]:
    return [TextContent(type="text", text=json.dumps(data, indent=2, default=str))]


def _text_result(text: str) -> list[TextContent]:
    return [TextContent(type="text", text=text)]


def _call_rpc(method: str, params: dict) -> Any:
    """Delegate to the RPC server handler."""
    request = {"jsonrpc": "2.0", "id": "mcp", "method": method, "params": params}
    response = handle_request(request)

    if "error" in response:
        err = response["error"]
        raise RuntimeError(f"RPC error {err.get('code', '?')}: {err.get('message', 'Unknown error')}")

    return response.get("result")


# ── MCP tool name -> RPC method mapping ───────────────────────────

METHOD_MAP = {
    # Generation
    "generate": "generate_music",
    "agent_chat": "ask_majik",
    "enhance_caption": "enhance_caption",
    "extract_parameters": "extract_music_parameters",
    "generate_track_name": "generate_track_name",
    # Library
    "list_tracks": "list_library_tracks",
    "list_albums": "list_library_albums",
    "list_artists": "list_library_artists",
    "import_track": "import_track",
    "import_audio": "import_audio",
    # Export
    "export_track": "export_track",
    "export_stems": "export_stems",
    # Audio analysis
    "analyze_audio": "analyze_audio_file",
    "generate_lyrics_timestamps": "generate_lyrics_timestamps",
    # Artwork
    "set_track_artwork": "set_track_artwork",
    "set_album_artwork": "set_album_artwork",
    "set_artist_artwork": "set_artist_artwork",
    "art_studio_health": "art_studio_health",
    "generate_track_artwork": "generate_track_artwork",
    "generate_album_artwork": "generate_album_artwork",
    "generate_artist_artwork": "generate_artist_artwork",
    # Publishing
    "publish_track": "publish_track",
    "unpublish_track": "unpublish_track",
    "update_published_track": "update_published_track",
    "fetch_catalogue": "fetch_catalogue",
    "convert_for_publish": "convert_audio_for_publish",
    "compute_fingerprint": "compute_fingerprint",
    "fetch_provenance": "fetch_provenance",
    # Artist profiles
    "list_artist_profiles": "list_artist_profiles",
    "create_artist_profile": "create_artist_profile",
    "update_artist_profile": "update_artist_profile",
    # Models & providers
    "list_models": "list_models",
    "list_llm_providers": "list_llm_providers",
    "set_llm_provider": "set_llm_provider",
    "unload_models": "unload_models",
    "unload_llm": "unload_llm",
    # Pipeline
    "generate_from_package": "import_song_package",
    "generate_variation": "generate_variation",
    "batch_generate": "batch_import_packages",
    # System
    "status": "ping",
    "system_info": "get_system_info",
}


# ── Tool definitions ──────────────────────────────────────────────

TOOLS = [
    # ─── Generation ───────────────────────────────────────────────
    Tool(
        name="generate",
        description="Generate AI music with ACE-Step. Returns audio file path(s) and metadata (BPM, key, duration).",
        inputSchema={
            "type": "object",
            "properties": {
                "caption": {"type": "string", "description": "Music style/genre description (e.g. 'upbeat synthwave with arpeggiated bass')"},
                "lyrics": {"type": "string", "description": "Song lyrics (omit for instrumental)"},
                "bpm": {"type": "integer", "description": "Tempo in BPM (60-180)"},
                "key": {"type": "string", "description": "Musical key (e.g. 'C Major', 'Dm')"},
                "duration": {"type": "integer", "description": "Duration in seconds (30-600, default 150)"},
                "count": {"type": "integer", "description": "Number of variants to generate (1-5, default 1)"},
                "output_dir": {"type": "string", "description": "Output directory (default ./output)"},
                "seed": {"type": "integer", "description": "Random seed for reproducibility"},
                "num_inference_steps": {"type": "integer", "description": "Inference steps (default 8 for turbo)"},
                "guidance_scale": {"type": "number", "description": "Guidance scale (default 4.5)"},
            },
            "required": ["caption"],
        },
    ),
    Tool(
        name="agent_chat",
        description="Chat with the Majik Agent — an AI music producer that helps craft songs through conversation, then extracts generation parameters.",
        inputSchema={
            "type": "object",
            "properties": {
                "message": {"type": "string", "description": "Your message to the agent"},
                "history": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "Chat history [{role, content}, ...]",
                },
                "allow_auto_generation": {"type": "boolean", "description": "Allow agent to trigger generation (default false)"},
            },
            "required": ["message"],
        },
    ),
    Tool(
        name="enhance_caption",
        description="Enhance a rough style/genre description into a detailed, production-quality caption for generation.",
        inputSchema={
            "type": "object",
            "properties": {
                "caption": {"type": "string", "description": "Rough style description to enhance"},
            },
            "required": ["caption"],
        },
    ),
    Tool(
        name="extract_parameters",
        description="Extract music generation parameters (BPM, key, duration, style, lyrics) from a conversation history.",
        inputSchema={
            "type": "object",
            "properties": {
                "history": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "Conversation history [{role, content}, ...]",
                },
            },
            "required": ["history"],
        },
    ),
    Tool(
        name="generate_track_name",
        description="Generate a creative track title from metadata.",
        inputSchema={
            "type": "object",
            "properties": {
                "caption": {"type": "string", "description": "Style/genre caption"},
                "lyrics": {"type": "string", "description": "Song lyrics"},
                "bpm": {"type": "integer"},
                "key": {"type": "string"},
                "artist": {"type": "string"},
                "genre": {"type": "string"},
            },
        },
    ),
    # ─── Library ──────────────────────────────────────────────────
    Tool(
        name="list_tracks",
        description="List all tracks in the local music library with metadata (title, artist, album, genre, BPM, key, duration, rating).",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="list_albums",
        description="List all albums in the local library with track counts and genres.",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="list_artists",
        description="List all artists in the local library with genres and track counts.",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="import_track",
        description="Import a track into the library with metadata (and optional audio file or URL).",
        inputSchema={
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Track title"},
                "artist": {"type": "string", "description": "Artist name"},
                "album": {"type": "string", "description": "Album name"},
                "genre": {"type": "string", "description": "Genre"},
                "lyrics": {"type": "string", "description": "Song lyrics"},
                "bpm": {"type": "integer", "description": "BPM"},
                "musicalKey": {"type": "string", "description": "Musical key"},
                "duration": {"type": "number", "description": "Duration in seconds"},
                "audio_path": {"type": "string", "description": "Path to audio file to import"},
                "audio_url": {"type": "string", "description": "URL to download audio from"},
            },
            "required": ["title"],
        },
    ),
    Tool(
        name="import_audio",
        description="Import an external audio file into the library (auto-detects metadata from filename).",
        inputSchema={
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path to audio file"},
                "output_dir": {"type": "string", "description": "Library subdirectory"},
            },
            "required": ["file_path"],
        },
    ),
    # ─── Export ───────────────────────────────────────────────────
    Tool(
        name="export_track",
        description="Export a library track to WAV, FLAC, MP3, or M4A format.",
        inputSchema={
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path to source audio file"},
                "output_path": {"type": "string", "description": "Destination file path"},
                "format": {"type": "string", "enum": ["wav", "flac", "mp3", "m4a"], "description": "Output format"},
                "bitrate": {"type": "string", "description": "Bitrate for lossy formats (e.g. '320k')"},
            },
            "required": ["file_path", "output_path", "format"],
        },
    ),
    Tool(
        name="export_stems",
        description="Export audio stems (vocals, drums, bass, other) for multi-track mixing.",
        inputSchema={
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path to source audio file"},
                "output_dir": {"type": "string", "description": "Output directory for stems"},
            },
            "required": ["file_path", "output_dir"],
        },
    ),
    # ─── Audio Analysis ──────────────────────────────────────────
    Tool(
        name="analyze_audio",
        description="Analyze an audio file to detect BPM, musical key, duration, and optionally genre/style via LLM.",
        inputSchema={
            "type": "object",
            "properties": {
                "file_path": {"type": "string", "description": "Path to audio file"},
                "caption": {"type": "string", "description": "Optional style context for LLM analysis"},
                "title": {"type": "string", "description": "Track title for LLM context"},
            },
            "required": ["file_path"],
        },
    ),
    Tool(
        name="generate_lyrics_timestamps",
        description="Generate synced LRC lyrics file with timestamps using forced alignment.",
        inputSchema={
            "type": "object",
            "properties": {
                "audio_path": {"type": "string", "description": "Path to audio file"},
                "lyrics": {"type": "string", "description": "Song lyrics text"},
                "output_path": {"type": "string", "description": "Output .lrc file path"},
            },
            "required": ["audio_path", "lyrics", "output_path"],
        },
    ),
    # ─── Artwork ─────────────────────────────────────────────────
    Tool(
        name="set_track_artwork",
        description="Assign custom artwork to a library track.",
        inputSchema={
            "type": "object",
            "properties": {
                "track_id": {"type": "string", "description": "Track ID"},
                "artwork_path": {"type": "string", "description": "Path to artwork image"},
            },
            "required": ["track_id", "artwork_path"],
        },
    ),
    Tool(
        name="set_album_artwork",
        description="Assign artwork to all tracks in an album.",
        inputSchema={
            "type": "object",
            "properties": {
                "album": {"type": "string", "description": "Album name"},
                "artwork_path": {"type": "string", "description": "Path to artwork image"},
            },
            "required": ["album", "artwork_path"],
        },
    ),
    Tool(
        name="set_artist_artwork",
        description="Assign artwork to all tracks by an artist.",
        inputSchema={
            "type": "object",
            "properties": {
                "artist": {"type": "string", "description": "Artist name"},
                "artwork_path": {"type": "string", "description": "Path to artwork image"},
            },
            "required": ["artist", "artwork_path"],
        },
    ),
    Tool(
        name="art_studio_health",
        description="Check if Majik's Art Studio companion app is running (localhost:8420).",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="generate_track_artwork",
        description="Generate track cover artwork via Art Studio (requires Art Studio running).",
        inputSchema={
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Track title"},
                "artist": {"type": "string", "description": "Artist name"},
                "album": {"type": "string", "description": "Album name"},
                "genre": {"type": "string", "description": "Genre for style matching"},
                "prompt": {"type": "string", "description": "Custom artwork prompt"},
                "track_id": {"type": "string", "description": "Track ID to auto-assign artwork"},
            },
            "required": ["title", "artist"],
        },
    ),
    Tool(
        name="generate_album_artwork",
        description="Generate album cover artwork via Art Studio (requires Art Studio running).",
        inputSchema={
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Album title"},
                "artist": {"type": "string", "description": "Artist name"},
                "genre": {"type": "string", "description": "Genre for style matching"},
                "track_count": {"type": "integer", "description": "Number of tracks"},
                "prompt": {"type": "string", "description": "Custom artwork prompt"},
            },
            "required": ["title", "artist"],
        },
    ),
    Tool(
        name="generate_artist_artwork",
        description="Generate artist profile photo via Art Studio (requires Art Studio running).",
        inputSchema={
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "Artist name"},
                "role": {"type": "string", "description": "Artist role/persona"},
                "prompt": {"type": "string", "description": "Custom portrait prompt"},
            },
            "required": ["name"],
        },
    ),
    # ─── Publishing ──────────────────────────────────────────────
    Tool(
        name="publish_track",
        description="Publish a track to majiks.online (requires Publisher license and Keycloak auth).",
        inputSchema={
            "type": "object",
            "properties": {
                "audio_path": {"type": "string", "description": "Path to FLAC audio file"},
                "stream_path": {"type": "string", "description": "Path to M4A 256k stream file"},
                "stream_low_path": {"type": "string", "description": "Path to M4A 128k stream file"},
                "keycloak_id": {"type": "string", "description": "Keycloak user ID"},
                "title": {"type": "string", "description": "Track title"},
                "artist": {"type": "string", "description": "Artist name"},
                "genre": {"type": "string", "description": "Genre"},
                "studio_track_id": {"type": "string", "description": "Local library track ID"},
                "artwork_path": {"type": "string", "description": "Path to artwork image"},
                "album": {"type": "string"},
                "lyrics": {"type": "string"},
                "bpm": {"type": "integer"},
                "musicalKey": {"type": "string"},
                "caption": {"type": "string"},
                "description": {"type": "string"},
                "tags": {"type": "string"},
            },
            "required": ["audio_path", "keycloak_id", "title"],
        },
    ),
    Tool(
        name="unpublish_track",
        description="Remove a published track from majiks.online.",
        inputSchema={
            "type": "object",
            "properties": {
                "track_id": {"type": "string", "description": "Published track ID"},
                "keycloak_id": {"type": "string", "description": "Keycloak user ID"},
            },
            "required": ["track_id", "keycloak_id"],
        },
    ),
    Tool(
        name="update_published_track",
        description="Update metadata on a published track (title, genre, lyrics, artwork, etc.).",
        inputSchema={
            "type": "object",
            "properties": {
                "track_id": {"type": "string", "description": "Published track ID"},
                "keycloak_id": {"type": "string", "description": "Keycloak user ID"},
                "title": {"type": "string"},
                "artist": {"type": "string"},
                "genre": {"type": "string"},
                "album": {"type": "string"},
                "lyrics": {"type": "string"},
                "artwork_path": {"type": "string", "description": "New artwork image path"},
                "description": {"type": "string"},
                "tags": {"type": "string"},
            },
            "required": ["track_id", "keycloak_id"],
        },
    ),
    Tool(
        name="fetch_catalogue",
        description="Fetch user's published track catalogue from majiks.online.",
        inputSchema={
            "type": "object",
            "properties": {
                "keycloak_id": {"type": "string", "description": "Keycloak user ID"},
                "offset": {"type": "integer", "description": "Pagination offset"},
                "limit": {"type": "integer", "description": "Page size (default 50)"},
            },
            "required": ["keycloak_id"],
        },
    ),
    Tool(
        name="convert_for_publish",
        description="Convert audio to FLAC (lossless) + M4A 256k + M4A 128k for publishing.",
        inputSchema={
            "type": "object",
            "properties": {
                "source_path": {"type": "string", "description": "Path to source audio (WAV)"},
            },
            "required": ["source_path"],
        },
    ),
    Tool(
        name="compute_fingerprint",
        description="Compute AcoustID audio fingerprint for duplicate detection.",
        inputSchema={
            "type": "object",
            "properties": {
                "audio_path": {"type": "string", "description": "Path to audio file"},
            },
            "required": ["audio_path"],
        },
    ),
    Tool(
        name="fetch_provenance",
        description="Fetch AI provenance certificate for a published track.",
        inputSchema={
            "type": "object",
            "properties": {
                "track_id": {"type": "string", "description": "Published track ID"},
            },
            "required": ["track_id"],
        },
    ),
    # ─── Artist Profiles ─────────────────────────────────────────
    Tool(
        name="list_artist_profiles",
        description="List artist profiles on majiks.online for a user.",
        inputSchema={
            "type": "object",
            "properties": {
                "keycloak_id": {"type": "string", "description": "Keycloak user ID"},
            },
            "required": ["keycloak_id"],
        },
    ),
    Tool(
        name="create_artist_profile",
        description="Create a new artist profile on majiks.online.",
        inputSchema={
            "type": "object",
            "properties": {
                "keycloak_id": {"type": "string", "description": "Keycloak user ID"},
                "artist_name": {"type": "string", "description": "Artist display name"},
            },
            "required": ["keycloak_id", "artist_name"],
        },
    ),
    Tool(
        name="update_artist_profile",
        description="Update an artist profile (name, website, social links).",
        inputSchema={
            "type": "object",
            "properties": {
                "profile_id": {"type": "string", "description": "Profile ID"},
                "keycloak_id": {"type": "string", "description": "Keycloak user ID"},
                "artist_name": {"type": "string"},
                "website": {"type": "string"},
                "social_links": {"type": "object", "description": "Social media links dict"},
            },
            "required": ["profile_id", "keycloak_id"],
        },
    ),
    # ─── Models & Providers ──────────────────────────────────────
    Tool(
        name="list_models",
        description="List available ACE-Step generation models.",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="list_llm_providers",
        description="List available LLM providers (MLX, OpenRouter, Anthropic, OpenAI, DeepSeek, Gemini).",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="set_llm_provider",
        description="Set the active LLM provider for chat and extraction.",
        inputSchema={
            "type": "object",
            "properties": {
                "provider": {"type": "string", "description": "Provider name"},
                "fallback_provider": {"type": "string", "description": "Fallback provider"},
            },
            "required": ["provider"],
        },
    ),
    Tool(
        name="unload_models",
        description="Unload ACE-Step generation models from memory.",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="unload_llm",
        description="Unload the chat LLM from memory.",
        inputSchema={"type": "object", "properties": {}},
    ),
    # ─── Pipeline ─────────────────────────────────────────────────
    Tool(
        name="generate_from_package",
        description="Generate music from a Songwriter app song package. Accepts tags, lyrics, BPM, duration, genre, mood, and pipeline metadata.",
        inputSchema={
            "type": "object",
            "properties": {
                "tags": {"type": "string", "description": "ACE-Step style tags (e.g. 'upbeat pop, catchy melody')"},
                "lyrics": {"type": "string", "description": "Song lyrics"},
                "bpm": {"type": "integer", "description": "Target BPM"},
                "key": {"type": "string", "description": "Musical key"},
                "duration": {"type": "integer", "description": "Duration in seconds (30-600)"},
                "genre": {"type": "string", "description": "Genre label"},
                "mood": {"type": "string", "description": "Mood descriptor"},
                "artist": {"type": "string", "description": "Artist name"},
                "album": {"type": "string", "description": "Album name"},
                "content_type": {"type": "string", "description": "Content type: news_narrative, news_beats, personal"},
                "inspired_by": {"type": "string", "description": "Source inspiration"},
                "source_urls": {"type": "array", "items": {"type": "string"}, "description": "Source URLs"},
                "topic": {"type": "string", "description": "Topic"},
                "topic_tags": {"type": "array", "items": {"type": "string"}, "description": "Topic tags"},
                "seed": {"type": "integer", "description": "Random seed"},
                "output_dir": {"type": "string", "description": "Output directory"},
            },
            "required": ["tags"],
        },
    ),
    Tool(
        name="generate_variation",
        description="Generate a genre variation of an existing track. Keeps lyrics, adjusts tags and BPM for the target genre.",
        inputSchema={
            "type": "object",
            "properties": {
                "tags": {"type": "string", "description": "Original track style tags"},
                "lyrics": {"type": "string", "description": "Lyrics to keep"},
                "target_genre": {"type": "string", "description": "Target genre (e.g. 'jazz', 'reggae', 'edm')"},
                "bpm": {"type": "integer", "description": "BPM override (otherwise uses genre default)"},
                "key": {"type": "string", "description": "Musical key"},
                "duration": {"type": "integer", "description": "Duration in seconds"},
                "seed": {"type": "integer", "description": "Random seed"},
                "source_track_id": {"type": "string", "description": "UUID of original track"},
                "output_dir": {"type": "string", "description": "Output directory"},
            },
            "required": ["tags", "target_genre"],
        },
    ),
    Tool(
        name="batch_generate",
        description="Batch generate multiple tracks from song packages. Accepts an album/artist and array of track packages.",
        inputSchema={
            "type": "object",
            "properties": {
                "album": {"type": "string", "description": "Album name for all tracks"},
                "artist": {"type": "string", "description": "Artist name for all tracks"},
                "tracks": {
                    "type": "array",
                    "items": {"type": "object"},
                    "description": "Array of song package objects (same format as generate_from_package)",
                },
                "output_dir": {"type": "string", "description": "Output directory"},
            },
            "required": ["tracks"],
        },
    ),
    # ─── System ──────────────────────────────────────────────────
    Tool(
        name="status",
        description="Check if the Music Studio backend is running and responsive.",
        inputSchema={"type": "object", "properties": {}},
    ),
    Tool(
        name="system_info",
        description="Get system information (OS, architecture, Python version, memory).",
        inputSchema={"type": "object", "properties": {}},
    ),
]


# ── MCP handlers ──────────────────────────────────────────────────

@app.list_tools()
async def list_tools() -> list[Tool]:
    return TOOLS


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    rpc_method = METHOD_MAP.get(name)
    if not rpc_method:
        return _text_result(f"Unknown tool: {name}")

    try:
        result = _call_rpc(rpc_method, arguments)
        return _json_result(result)
    except Exception as e:
        return _text_result(f"Error: {e}")


# ── Resources ─────────────────────────────────────────────────────

@app.list_resources()
async def list_resources() -> list[Resource]:
    return [
        Resource(uri="music://library", name="Library", description="All tracks in the local music library"),
        Resource(uri="music://albums", name="Albums", description="All albums in the library"),
        Resource(uri="music://artists", name="Artists", description="All artists in the library"),
        Resource(uri="music://models", name="Models", description="Available ACE-Step generation models"),
        Resource(uri="music://providers", name="LLM Providers", description="Available LLM providers and status"),
        Resource(uri="music://status", name="Status", description="Backend status and system info"),
    ]


@app.read_resource()
async def read_resource(uri: str) -> str:
    if uri == "music://library":
        result = _call_rpc("list_library_tracks", {})
        return json.dumps(result, indent=2, default=str)

    elif uri == "music://albums":
        result = _call_rpc("list_library_albums", {})
        return json.dumps(result, indent=2, default=str)

    elif uri == "music://artists":
        result = _call_rpc("list_library_artists", {})
        return json.dumps(result, indent=2, default=str)

    elif uri == "music://models":
        result = _call_rpc("list_models", {})
        return json.dumps(result, indent=2, default=str)

    elif uri == "music://providers":
        result = _call_rpc("list_llm_providers", {})
        return json.dumps(result, indent=2, default=str)

    elif uri == "music://status":
        result = _call_rpc("ping", {})
        info = _call_rpc("get_system_info", {})
        return json.dumps({"ping": result, "system": info}, indent=2, default=str)

    raise ValueError(f"Unknown resource: {uri}")


# ── Entry point ───────────────────────────────────────────────────

async def _run():
    from mcp.server.stdio import stdio_server

    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


def main():
    import asyncio
    asyncio.run(_run())


if __name__ == "__main__":
    main()
