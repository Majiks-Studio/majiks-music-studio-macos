"""Publisher-related RPC method handlers.

Extracted from rpc_server.py to keep the main handler focused on
generation, library, and LLM concerns.  All methods communicate with
the majiks.online studio-bridge API.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
import tempfile
import urllib.parse
import urllib.request
import uuid
from typing import Any, Dict, Optional

from .rpc_server import RPCError, _raise_user_error, _progress

logger = logging.getLogger("majik.rpc")

# ── Publishing server configuration ────────────────────────────────

DEFAULT_PUBLISH_SERVER = "https://majiks.online"
DEFAULT_PUBLISH_TOKEN = "majiks-studio-bridge-2026"


def _publish_server_url() -> str:
    """Return the configured publishing server base URL."""
    return os.getenv("PUBLISH_SERVER_URL", DEFAULT_PUBLISH_SERVER).rstrip("/")


def _publish_auth_token() -> str:
    """Return the studio-bridge service token for the publishing server."""
    return os.getenv("PUBLISH_SERVER_API_KEY", DEFAULT_PUBLISH_TOKEN)


def _bridge_headers(content_type: Optional[str] = None, access_token: Optional[str] = None) -> Dict[str, str]:
    """Return common headers for studio-bridge API requests.

    When *access_token* (a Keycloak access token) is provided it is used as the
    Bearer token and the server extracts the user identity from it directly.
    Otherwise falls back to the legacy static bridge key.
    """
    token = access_token if access_token else _publish_auth_token()
    h: Dict[str, str] = {
        "Authorization": f"Bearer {token}",
        "User-Agent": "MajiksMusicStudio/3.2.0",
    }
    if content_type:
        h["Content-Type"] = content_type
    return h


# ── Publisher method dispatcher ─────────────────────────────────────

def handle_publisher_method(method: str, params: dict, request_id=None) -> dict | None:
    """Handle a publisher-related RPC method.

    Returns the result dict (with ``"result"`` key) for handled methods,
    or ``None`` if *method* is not a publisher method.
    """

    # ── Artist Profiles ────────────────────────────────────────────

    if method == "list_artist_profiles":
        keycloak_id = params.get("keycloak_id")
        if not keycloak_id:
            raise RPCError(-32602, "Missing required parameter: keycloak_id")

        query = urllib.parse.urlencode({
            "keycloak_id": keycloak_id,
            "offset": params.get("offset", 0),
            "limit": params.get("limit", 100),
        })
        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles?{query}"

        req = urllib.request.Request(
            url,
            headers=_bridge_headers(),
            method="GET",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="artist_profiles")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="artist_profiles",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="artist_profiles")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="artist_profiles")

    if method == "create_artist_profile":
        keycloak_id = params.get("keycloak_id")
        artist_name = params.get("artist_name")
        if not keycloak_id or not artist_name:
            raise RPCError(-32602, "Missing required parameters: keycloak_id, artist_name")

        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles"

        body = json.dumps({"keycloak_id": keycloak_id, "artist_name": artist_name}).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers=_bridge_headers("application/json"),
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="create_profile")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="create_profile",
                )
            if e.code == 409:
                _raise_user_error("SERVER_ERROR", f"Profile limit reached or duplicate name: {resp_body}", fix="Delete an existing profile first or use a different name", step="create_profile")
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="create_profile")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="create_profile")

    if method == "update_artist_profile":
        profile_id = params.get("profile_id")
        keycloak_id = params.get("keycloak_id")
        if not profile_id or not keycloak_id:
            raise RPCError(-32602, "Missing required parameters: profile_id, keycloak_id")

        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles/{profile_id}"

        body_dict: Dict[str, Any] = {"keycloak_id": keycloak_id}
        for field in ("artist_name", "website", "social_links"):
            val = params.get(field)
            if val is not None:
                body_dict[field] = val

        body = json.dumps(body_dict).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers=_bridge_headers("application/json"),
            method="PUT",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="update_profile")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="update_profile",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="update_profile")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="update_profile")

    if method == "delete_artist_profile":
        profile_id = params.get("profile_id")
        keycloak_id = params.get("keycloak_id")
        if not profile_id or not keycloak_id:
            raise RPCError(-32602, "Missing required parameters: profile_id, keycloak_id")

        query = urllib.parse.urlencode({"keycloak_id": keycloak_id})
        url = f"{_publish_server_url()}/api/studio-bridge/artist-profiles/{profile_id}?{query}"

        req = urllib.request.Request(
            url,
            headers=_bridge_headers(),
            method="DELETE",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="delete_profile")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="delete_profile",
                )
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
                  f"Converted: {source_size_mb}MB \u2192 FLAC {flac_size_mb}MB + M4A 256k {m4a_size_mb}MB + M4A 128k {m4a_low_size_mb}MB")

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
        title = params.get("title")
        studio_track_id = params.get("studio_track_id")

        if not all([audio_path, keycloak_id, title, studio_track_id]):
            raise RPCError(-32602, "Missing required parameters: audio_path/m4a_path, keycloak_id, title, studio_track_id")

        if not os.path.exists(audio_path):
            _raise_user_error(
                "PUBLISH_FAILED",
                f"Audio file not found: {audio_path}",
                step="upload",
            )

        _progress(request_id, "upload", 10, "Preparing upload...")

        # Build multipart/form-data body using stdlib
        boundary = f"----MajikStudioBridge{uuid.uuid4().hex}"
        body_parts: list[bytes] = []

        # Text fields
        form_fields: Dict[str, str] = {
            "keycloak_id": keycloak_id,
            "title": title[:500],
            "studio_track_id": studio_track_id,
        }
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

        # Stream file -- M4A 256kbps (standard streaming)
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

        # Stream file low -- M4A 128kbps (mobile / free tier)
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
            headers=_bridge_headers(f"multipart/form-data; boundary={boundary}"),
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="upload")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
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

        track_id = resp_data.get("data", {}).get("trackId", "")
        track_slug = resp_data.get("data", {}).get("trackSlug", "")
        track_url = f"{_publish_server_url()}/track/{track_slug}" if track_slug else ""
        track_isrc = resp_data.get("data", {}).get("isrc", "")

        _progress(request_id, "upload", 100, f"Published: {track_url}")

        result = {
            "success": True,
            "track_id": str(track_id),
            "track_slug": track_slug,
            "url": track_url,
        }
        if track_isrc:
            result["isrc"] = track_isrc

        return {"result": result}

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
        if not fingerprint or not keycloak_id:
            raise RPCError(-32602, "Missing required parameters: fingerprint, keycloak_id")

        lookup_url = f"{_publish_server_url()}/api/studio-bridge/fingerprint-lookup"

        body = json.dumps({"fingerprint": fingerprint, "keycloak_id": keycloak_id}).encode()
        req = urllib.request.Request(
            lookup_url,
            data=body,
            headers=_bridge_headers("application/json"),
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="fingerprint_lookup")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="fingerprint_lookup",
                )
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
        if not keycloak_id:
            raise RPCError(-32602, "Missing required parameter: keycloak_id")

        offset = int(params.get("offset", 0))
        limit = int(params.get("limit", 50))

        query = urllib.parse.urlencode({"keycloak_id": keycloak_id, "offset": offset, "limit": limit})
        catalogue_url = f"{_publish_server_url()}/api/studio-bridge/catalogue?{query}"

        req = urllib.request.Request(
            catalogue_url,
            headers=_bridge_headers(),
            method="GET",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="catalogue")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="catalogue",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="catalogue")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="catalogue")

    if method == "update_published_track":
        track_id = params.get("track_id")
        keycloak_id = params.get("keycloak_id")
        if not track_id or not keycloak_id:
            raise RPCError(-32602, "Missing required parameters: track_id, keycloak_id")

        update_url = f"{_publish_server_url()}/api/studio-bridge/tracks/{track_id}"
        artwork_path = params.get("artwork_path")

        # All supported PATCH fields
        _patch_fields = (
            "title", "genre", "subgenre", "artist", "album", "bpm", "musical_key",
            "lyrics", "lyrics_lrc", "artist_profile_id", "mood", "energy",
            "tags", "language", "backstory", "backstory_visibility",
            "description", "studio_track_id", "parent_track_id", "visibility",
            "explicit", "credits", "isrc",
        )

        # If artwork is provided, use multipart/form-data
        if artwork_path and os.path.exists(artwork_path):
            boundary = f"----MajikStudioBridge{uuid.uuid4().hex}"
            body_parts: list[bytes] = []

            # Text fields
            form_fields: Dict[str, str] = {"keycloak_id": keycloak_id}
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
                headers=_bridge_headers(f"multipart/form-data; boundary={boundary}"),
                method="PATCH",
            )
        else:
            # JSON-only update (no artwork)
            body_dict: Dict[str, Any] = {"keycloak_id": keycloak_id}
            for field in _patch_fields:
                val = params.get(field)
                if val is not None:
                    body_dict[field] = val

            body = json.dumps(body_dict).encode()
            req = urllib.request.Request(
                update_url,
                data=body,
                headers=_bridge_headers("application/json"),
                method="PATCH",
            )

        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="update_track")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="update_track",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="update_track")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="update_track")

    if method == "fetch_creator_sales":
        keycloak_id = params.get("keycloak_id")
        view = params.get("view", "summary")
        period = params.get("period", "month")
        if not keycloak_id:
            raise RPCError(-32602, "Missing required parameter: keycloak_id")

        url = f"{_publish_server_url()}/api/studio-bridge/creator/sales?keycloak_id={keycloak_id}&view={view}&period={period}"
        req = urllib.request.Request(
            url,
            headers=_bridge_headers(),
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="creator_sales")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="creator_sales",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="creator_sales")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="creator_sales")

    if method == "fetch_creator_earnings":
        keycloak_id = params.get("keycloak_id")
        view = params.get("view", "summary")
        if not keycloak_id:
            raise RPCError(-32602, "Missing required parameter: keycloak_id")

        url = f"{_publish_server_url()}/api/studio-bridge/creator/earnings?keycloak_id={keycloak_id}&view={view}"
        req = urllib.request.Request(
            url,
            headers=_bridge_headers(),
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="creator_earnings")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="creator_earnings",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="creator_earnings")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="creator_earnings")

    if method == "fetch_creator_catalog":
        keycloak_id = params.get("keycloak_id")
        view = params.get("view", "summary")
        query = params.get("q", "")
        status = params.get("status", "")
        page = int(params.get("page", 1))
        limit = int(params.get("limit", 50))
        if not keycloak_id:
            raise RPCError(-32602, "Missing required parameter: keycloak_id")

        url_params = f"keycloak_id={keycloak_id}&view={view}&page={page}&limit={limit}"
        if query:
            url_params += f"&q={urllib.parse.quote(query)}"
        if status:
            url_params += f"&status={urllib.parse.quote(status)}"
        url = f"{_publish_server_url()}/api/studio-bridge/creator/catalog?{url_params}"
        req = urllib.request.Request(
            url,
            headers=_bridge_headers(),
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="creator_catalog")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="creator_catalog",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="creator_catalog")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="creator_catalog")

    if method == "file_dmca_claim":
        keycloak_id = params.get("keycloak_id")
        track_id = params.get("track_id")
        reason = params.get("reason", "")
        claimant_name = params.get("claimant_name", "")
        claimant_email = params.get("claimant_email", "")
        provenance_cert_id = params.get("provenance_cert_id", "")
        evidence_urls = params.get("evidence_urls", [])
        if not keycloak_id or not track_id:
            raise RPCError(-32602, "Missing required parameters: keycloak_id, track_id")
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
            headers=_bridge_headers("application/json"),
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="dmca")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="dmca",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="dmca")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="dmca")

    if method == "unpublish_track":
        track_id = params.get("track_id")
        keycloak_id = params.get("keycloak_id")
        if not track_id or not keycloak_id:
            raise RPCError(-32602, "Missing required parameters: track_id, keycloak_id")

        query = urllib.parse.urlencode({"keycloak_id": keycloak_id})
        delete_url = f"{_publish_server_url()}/api/studio-bridge/tracks/{track_id}?{query}"

        req = urllib.request.Request(
            delete_url,
            headers=_bridge_headers(),
            method="DELETE",
        )

        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                resp_body = resp.read().decode()
                resp_data = json.loads(resp_body)
            return {"result": resp_data}
        except urllib.error.HTTPError as e:
            resp_body = e.read().decode()[:300] if e.fp else ""
            if e.code == 401:
                _raise_user_error("AUTH_FAILED", f"Authentication failed ({e.code}): {resp_body}", step="unpublish")
            if e.code == 403:
                # NOT an auth failure. authenticateBridge only ever answers 401
                # for that; a 403 means the token was ACCEPTED and the plan
                # does not allow this action.
                _raise_user_error(
                    "PERMISSION_DENIED",
                    f"Your majiks.online plan does not allow this ({e.code}): {resp_body}",
                    fix="Upgrade your majiks.online plan, or free up room by removing something first",
                    step="unpublish",
                )
            _raise_user_error("SERVER_ERROR", f"Server returned {e.code}: {resp_body}", fix="Check your internet connection and try again", step="unpublish")
        except urllib.error.URLError as e:
            _raise_user_error("NETWORK_ERROR", f"Network error: {e.reason}", fix="Check your internet connection and try again", step="unpublish")

    # Method not handled by publisher module
    return None
