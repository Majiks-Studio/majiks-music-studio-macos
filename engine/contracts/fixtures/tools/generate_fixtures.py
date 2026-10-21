#!/usr/bin/env python3
"""Deterministic fixture generator for engine/contracts/fixtures/.

Fixtures are committed as static files; this script is how they were produced
and can reproduce them byte-for-byte (re-run it and `git diff` should be empty).
It is not part of the conformance boot-test (that is plain `cargo test` /
`python3 -m pytest engine/contracts/`, no generation step); it is a maintenance
tool, run by hand when fixtures need to change, per engine/contracts/README.md
"Change control".

Usage: python3 engine/contracts/fixtures/tools/generate_fixtures.py
(run from anywhere; paths below are resolved relative to this file)
"""
import json
import sys
from pathlib import Path

CONTRACTS_DIR = Path(__file__).resolve().parents[2]
FIXTURES_DIR = CONTRACTS_DIR / "fixtures"

sys.path.insert(0, str(CONTRACTS_DIR))
from conformance_py.canonical import GENESIS_HASH, compute_entry_hash  # noqa: E402
from conformance_py.blake3_compat import blake3_hex  # noqa: E402


def ulid(seed: int) -> str:
    """Deterministic, correctly-shaped 26-char Crockford32 ULID for fixtures.
    Not a real monotonic-timestamp ULID generator (fixtures need to be
    reproducible, not time-based)."""
    crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    n = seed
    chars = []
    for _ in range(25):
        chars.append(crockford[n % 32])
        n //= 32
    body = "".join(reversed(chars))
    first = crockford[(seed // 7) % 8]  # keep within 0-7 per the ULID pattern
    return first + body


def asset_hash(label: str) -> str:
    """A real blake3 hex digest of a deterministic placeholder byte string, so
    fixture assetHash fields are genuine 64-hex-char blake3 output (not a
    hand-typed string that merely looks like one)."""
    return blake3_hex(f"fixture-placeholder-audio-bytes:{label}".encode("ascii"))


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2, sort_keys=False)
        f.write("\n")


# ---------------------------------------------------------------------------
# fixtures/project/: 30-entry journal + matching checkpoint
# ---------------------------------------------------------------------------

def build_journal():
    base_ts = "2026-07-11T20:04:"  # seconds appended per entry, then minute rollover handled below

    def ts_for(i: int) -> str:
        total_seconds = 1 + (i - 1) * 5
        minute = 4 + total_seconds // 60
        second = total_seconds % 60
        return f"2026-07-11T20:{minute:02d}:{second:02d}Z"

    ah_drums = asset_hash("drums-loop-1")
    ah_bass = asset_hash("bass-loop-1")

    user = {"kind": "user", "name": "aaron"}
    agent = {"kind": "agent", "name": "studio-copilot"}
    copilot = {"kind": "copilot", "name": "studio-copilot"}

    # (actor, name, params, inverse_name_or_self, inverse_params)
    steps = [
        (user, "project.setTempo", {"bpm": 92}, "project.setTempo", {"bpm": 120}),
        (user, "track.add", {"trackId": "trk_drums", "name": "Drums", "index": 0}, "track.remove", {"trackId": "trk_drums"}),
        (user, "track.add", {"trackId": "trk_bass", "name": "Bass", "index": 1}, "track.remove", {"trackId": "trk_bass"}),
        (user, "track.add", {"trackId": "trk_synth", "name": "Synth", "index": 2}, "track.remove", {"trackId": "trk_synth"}),
        (agent, "track.setColor", {"trackId": "trk_drums", "color": "#E05252"}, "track.setColor", {"trackId": "trk_drums", "color": "#FFFFFF"}),
        (agent, "track.setColor", {"trackId": "trk_bass", "color": "#4C7CE0"}, "track.setColor", {"trackId": "trk_bass", "color": "#FFFFFF"}),
        (user, "clip.place", {"clipId": "clip_drums_1", "trackId": "trk_drums", "assetHash": ah_drums, "startTicks": 0, "lengthTicks": 7680}, "clip.remove", {"clipId": "clip_drums_1"}),
        (user, "clip.place", {"clipId": "clip_bass_1", "trackId": "trk_bass", "assetHash": ah_bass, "startTicks": 0, "lengthTicks": 7680}, "clip.remove", {"clipId": "clip_bass_1"}),
        (user, "clip.move", {"clipId": "clip_bass_1", "trackId": "trk_bass", "startTicks": 960}, "clip.move", {"clipId": "clip_bass_1", "trackId": "trk_bass", "startTicks": 0}),
        (user, "clip.trim", {"clipId": "clip_drums_1", "edge": "end", "deltaTicks": -960}, "clip.trim", {"clipId": "clip_drums_1", "edge": "end", "deltaTicks": 960}),
        (user, "clip.setGain", {"clipId": "clip_drums_1", "gainDb": -3}, "clip.setGain", {"clipId": "clip_drums_1", "gainDb": 0}),
        (user, "clip.fade.set", {"clipId": "clip_drums_1", "edge": "in", "lengthTicks": 240, "shape": "linear"}, "clip.fade.set", {"clipId": "clip_drums_1", "edge": "in", "lengthTicks": 0, "shape": "linear"}),
        (user, "mix.gain", {"trackId": "trk_drums", "gainDb": -2}, "mix.gain", {"trackId": "trk_drums", "gainDb": 0}),
        (user, "mix.pan", {"trackId": "trk_synth", "pan": 1}, "mix.pan", {"trackId": "trk_synth", "pan": 0}),
        (user, "mix.eq", {"trackId": "trk_bass", "band": 0, "freqHz": 80, "gainDb": 3}, "mix.eq", {"trackId": "trk_bass", "band": 0, "freqHz": 80, "gainDb": 0}),
        (user, "mix.send", {"trackId": "trk_synth", "bus": "a", "amount": 1}, "mix.send", {"trackId": "trk_synth", "bus": "a", "amount": 0}),
        (user, "track.mute", {"trackId": "trk_synth", "muted": True}, "track.mute", {"trackId": "trk_synth", "muted": False}),
        (user, "track.mute", {"trackId": "trk_synth", "muted": False}, "track.mute", {"trackId": "trk_synth", "muted": True}),
        (copilot, "track.solo", {"trackId": "trk_drums", "soloed": True}, "track.solo", {"trackId": "trk_drums", "soloed": False}),
        (copilot, "track.solo", {"trackId": "trk_drums", "soloed": False}, "track.solo", {"trackId": "trk_drums", "soloed": True}),
        (user, "section.set", {"sectionId": "sec_intro", "name": "Intro", "startTicks": 0}, "section.remove", {"sectionId": "sec_intro"}),
        (user, "section.set", {"sectionId": "sec_verse", "name": "Verse", "startTicks": 7680}, "section.remove", {"sectionId": "sec_verse"}),
        (user, "marker.set", {"markerId": "mk_1", "positionTicks": 3840, "label": "drop candidate"}, "marker.remove", {"markerId": "mk_1"}),
        (user, "autopoint.add", {"trackId": "trk_bass", "target": "track.volume", "pointId": "ap_1", "positionTicks": 0, "value": 0}, "autopoint.remove", {"trackId": "trk_bass", "target": "track.volume", "pointId": "ap_1"}),
        (user, "autopoint.add", {"trackId": "trk_bass", "target": "track.volume", "pointId": "ap_2", "positionTicks": 1920, "value": -6}, "autopoint.remove", {"trackId": "trk_bass", "target": "track.volume", "pointId": "ap_2"}),
        (user, "autopoint.move", {"trackId": "trk_bass", "target": "track.volume", "pointId": "ap_2", "positionTicks": 2880, "value": -6}, "autopoint.move", {"trackId": "trk_bass", "target": "track.volume", "pointId": "ap_2", "positionTicks": 1920, "value": -6}),
        (user, "txn.begin", {"txnId": "txn_1", "reason": "drag 3 clips"}, None, None),
        (user, "clip.move", {"clipId": "clip_drums_1", "trackId": "trk_drums", "startTicks": 960}, "clip.move", {"clipId": "clip_drums_1", "trackId": "trk_drums", "startTicks": 0}),
        (user, "clip.move", {"clipId": "clip_bass_1", "trackId": "trk_bass", "startTicks": 1920}, "clip.move", {"clipId": "clip_bass_1", "trackId": "trk_bass", "startTicks": 960}),
        (user, "txn.commit", {"txnId": "txn_1"}, None, None),
    ]
    assert len(steps) == 30, f"expected exactly 30 journal entries, got {len(steps)}"

    entries = []
    prev_hash = GENESIS_HASH
    for i, (actor, name, params, inv_name, inv_params) in enumerate(steps, start=1):
        inverse = None if inv_name is None else {"name": inv_name, "params": inv_params}
        entry = {
            "id": ulid(1000 + i),
            "ts": ts_for(i),
            "actor": actor,
            "name": name,
            "params": params,
            "inverse": inverse,
            "result": {"ok": True},
        }
        h = compute_entry_hash(prev_hash, entry)
        entry["hash"] = h
        entries.append(entry)
        prev_hash = h

    return entries, ah_drums, ah_bass


def build_project_json(entries, ah_drums, ah_bass):
    tip = entries[-1]
    return {
        "formatVersion": 1,
        "projectId": ulid(1),
        "name": "Late Night Drive",
        "tempo": {"bpm": 92},
        "timeSig": {"numerator": 4, "denominator": 4},
        "sampleRateHz": 48000,
        "ppq": 960,
        "sections": [
            {"sectionId": "sec_intro", "name": "Intro", "startTicks": 0},
            {"sectionId": "sec_verse", "name": "Verse", "startTicks": 7680},
        ],
        "markers": [
            {"markerId": "mk_1", "positionTicks": 3840, "label": "drop candidate"},
        ],
        "tracks": [
            {
                "trackId": "trk_drums", "name": "Drums", "index": 0, "color": "#E05252",
                "muted": False, "soloed": False, "gainDb": -2, "pan": 0,
            },
            {
                "trackId": "trk_bass", "name": "Bass", "index": 1, "color": "#4C7CE0",
                "muted": False, "soloed": False, "gainDb": 0, "pan": 0,
                "automation": {
                    "volume": [
                        {"pointId": "ap_1", "positionTicks": 0, "value": 0},
                        {"pointId": "ap_2", "positionTicks": 2880, "value": -6},
                    ]
                },
            },
            {
                "trackId": "trk_synth", "name": "Synth", "index": 2,
                "muted": False, "soloed": False, "gainDb": 0, "pan": 1,
                "sends": {"a": 1},
            },
        ],
        "clips": [
            {
                "clipId": "clip_drums_1", "trackId": "trk_drums", "assetHash": ah_drums,
                "startTicks": 960, "lengthTicks": 6720, "gainDb": -3,
                "fadeIn": {"lengthTicks": 240, "shape": "linear"},
            },
            {
                "clipId": "clip_bass_1", "trackId": "trk_bass", "assetHash": ah_bass,
                "startTicks": 1920, "lengthTicks": 7680,
            },
        ],
        "masterBus": {"gainDb": 0, "limiter": {"enabled": False}},
        "journal": {
            "entryCount": len(entries),
            "tipId": tip["id"],
            "tipHash": tip["hash"],
            "genesisHash": GENESIS_HASH,
            "checkpointedAt": "2026-07-11T20:06:36Z",
        },
    }


def write_project_fixtures():
    entries, ah_drums, ah_bass = build_journal()
    journal_path = FIXTURES_DIR / "project" / "minimal-journal.jsonl"
    journal_path.parent.mkdir(parents=True, exist_ok=True)
    with open(journal_path, "w") as f:
        for entry in entries:
            f.write(json.dumps(entry, sort_keys=False, separators=(",", ": ")) + "\n")

    project = build_project_json(entries, ah_drums, ah_bass)
    write_json(FIXTURES_DIR / "project" / "minimal-project.json", project)
    print(f"wrote {journal_path} ({len(entries)} entries, tip {entries[-1]['hash'][:12]}...)")
    print(f"wrote {FIXTURES_DIR / 'project' / 'minimal-project.json'}")


# ---------------------------------------------------------------------------
# fixtures/commands/valid/ + invalid/
# ---------------------------------------------------------------------------

def envelope(seed, actor, name, params, inverse, ts="2026-07-11T20:04:11Z", ok=True, extra=None):
    e = {
        "id": ulid(seed),
        "ts": ts,
        "actor": actor,
        "name": name,
        "params": params,
        "inverse": inverse,
        "result": {"ok": ok},
    }
    if extra:
        e.update(extra)
    prev = GENESIS_HASH
    e["hash"] = compute_entry_hash(prev, {k: e[k] for k in ("id", "ts", "actor", "name", "params", "inverse", "result")})
    return e


def write_valid_commands():
    user = {"kind": "user", "name": "aaron"}
    agent = {"kind": "agent", "name": "sarge-copilot"}

    fixtures = {}

    fixtures["project_setTempo.json"] = envelope(
        2001, user, "project.setTempo", {"bpm": 128}, {"name": "project.setTempo", "params": {"bpm": 92}})

    fixtures["track_add.json"] = envelope(
        2002, user, "track.add", {"trackId": "trk_pad", "name": "Pad", "index": 3},
        {"name": "track.remove", "params": {"trackId": "trk_pad"}})

    # Literally the worked example from 02-ARCHITECTURE.md section 4.
    fixtures["clip_move.json"] = envelope(
        2003, {"kind": "user", "name": "..."}, "clip.move",
        {"clipId": "clip_drums_1", "trackId": "trk_drums", "startTicks": 1920},
        {"name": "clip.move", "params": {"clipId": "clip_drums_1", "trackId": "trk_drums", "startTicks": 960}},
        ts="2026-07-11T20:04:11Z")

    fixtures["clip_warp_set_ratio.json"] = envelope(
        2004, user, "clip.warp.set", {"clipId": "clip_bass_1", "mode": "ratio", "stretchRatio": 1},
        {"name": "clip.warp.set", "params": {"clipId": "clip_bass_1", "mode": "ratio", "stretchRatio": 1}})

    fixtures["autopoint_add.json"] = envelope(
        2005, user, "autopoint.add",
        {"trackId": "trk_bass", "target": "track.pan", "pointId": "ap_9", "positionTicks": 480, "value": 0},
        {"name": "autopoint.remove", "params": {"trackId": "trk_bass", "target": "track.pan", "pointId": "ap_9"}})

    fixtures["mix_eq.json"] = envelope(
        2006, user, "mix.eq", {"trackId": "trk_synth", "band": 1, "freqHz": 2000, "gainDb": -4},
        {"name": "mix.eq", "params": {"trackId": "trk_synth", "band": 1, "freqHz": 2000, "gainDb": 0}})

    fixtures["gen_revise.json"] = envelope(
        2007, user, "gen.revise",
        {
            "requestId": ulid(9001), "clipId": "clip_drums_1",
            "regionStartTicks": 3840, "regionEndTicks": 5760, "scope": "drums",
            "request": {"instruction": "bigger, more aggressive drums in this section", "variants": 2},
        },
        None)

    fixtures["gen_finalize.json"] = envelope(
        2008, user, "gen.finalize",
        {
            "requestId": ulid(9002), "draftTakeId": "take_drums_draft_1", "targetQualityRung": "full",
            "request": {
                "requestId": ulid(9001), "sourceAudioRef": "clip_drums_1",
                "regionStartSeconds": 4, "regionEndSeconds": 6,
                "instruction": "bigger, more aggressive drums in this section",
            },
        },
        None)

    fixtures["take_promote.json"] = envelope(
        2009, agent, "take.promote", {"takeId": "take_drums_draft_1", "targetClipId": "clip_drums_1"},
        {"name": "take.discard", "params": {"takeId": "take_drums_draft_1"}})

    fixtures["import_audio.json"] = envelope(
        2010, user, "import.audio",
        {"sourcePath": "/Users/aaron/Desktop/vox-take-3.wav", "targetTrackId": "trk_vox", "separate": False, "conform": True},
        {"name": "clip.remove", "params": {"clipId": "clip_vox_imported_1"}})

    fixtures["export_master.json"] = envelope(
        2011, user, "export.master", {"outputPath": "/Users/aaron/Music/Bounces/late-night-drive.wav", "format": "wav"},
        None)

    fixtures["studio_importStemSession.json"] = envelope(
        2012, user, "studio.importStemSession", {"stemSessionId": "stem_session_42"},
        {"name": "track.remove", "params": {"trackId": "trk_pad"}})

    # marker.remove: added via P0-C proposal 1, APPROVED by the coordinating
    # session 2026-07-11. Inverse restores the removed marker via marker.set.
    fixtures["marker_remove.json"] = envelope(
        2013, user, "marker.remove", {"markerId": "mk_1"},
        {"name": "marker.set", "params": {"markerId": "mk_1", "positionTicks": 3840, "label": "drop candidate"}})

    assert len(fixtures) == 13, f"expected 13 valid command fixtures, got {len(fixtures)}"

    out_dir = FIXTURES_DIR / "commands" / "valid"
    manifest = []
    for filename, obj in fixtures.items():
        write_json(out_dir / filename, obj)
        manifest.append({"file": filename, "command": obj["name"]})
    write_json(out_dir / "manifest.json", {"count": len(fixtures), "fixtures": manifest})
    print(f"wrote {len(fixtures)} valid command fixtures to {out_dir}")


def write_invalid_commands():
    user = {"kind": "user", "name": "aaron"}
    good_move_params = {"clipId": "clip_drums_1", "trackId": "trk_drums", "startTicks": 960}
    good_move_inverse = {"name": "clip.move", "params": {"clipId": "clip_drums_1", "trackId": "trk_drums", "startTicks": 0}}

    out_dir = FIXTURES_DIR / "commands" / "invalid"
    manifest = []

    def emit(filename, obj, reason, hint):
        write_json(out_dir / filename, obj)
        manifest.append({"file": filename, "reason": reason, "hint": hint})

    # 1. unknown command name
    e = envelope(3001, user, "clip.telekinesis", {"clipId": "clip_drums_1"}, None)
    emit("unknown_command_name.json", e, "name is not in command-catalog.v1.json",
         "conformance must look up 'name' in the catalog and fail if absent; the envelope schema alone cannot catch this (it only checks the dotted-name shape)")

    # 2. missing required field (params)
    e = envelope(3002, user, "clip.move", good_move_params, good_move_inverse)
    del e["params"]
    emit("missing_required_field.json", e, "envelope is missing required field 'params'",
         "commandEnvelope.required")

    # 3. bad id format
    e = envelope(3003, user, "clip.move", good_move_params, good_move_inverse)
    e["id"] = "not-a-ulid"
    emit("bad_id_format.json", e, "id does not match the ULID pattern",
         "commandEnvelope.properties.id.pattern")

    # 4. bad hash format
    e = envelope(3004, user, "clip.move", good_move_params, good_move_inverse)
    e["hash"] = "xyz"
    emit("bad_hash_format.json", e, "hash is not 64 lowercase hex characters",
         "commandEnvelope.properties.hash.pattern")

    # 5. bad timestamp format
    e = envelope(3005, user, "clip.move", good_move_params, good_move_inverse)
    e["ts"] = "July 11 2026"
    emit("bad_timestamp_format.json", e, "ts is not a Zulu-suffixed ISO8601 timestamp",
         "commandEnvelope.properties.ts.pattern")

    # 6. bad actor kind
    e = envelope(3006, {"kind": "robot", "name": "aaron"}, "clip.move", good_move_params, good_move_inverse)
    emit("bad_actor_kind.json", e, "actor.kind 'robot' is not in the enum",
         "commandEnvelope.properties.actor.properties.kind.enum")

    # 7. params wrong type
    e = envelope(3007, user, "clip.move",
                 {"clipId": "clip_drums_1", "trackId": "trk_drums", "startTicks": "soon"}, good_move_inverse)
    emit("params_wrong_type.json", e, "params.startTicks is a string, clip.move's paramsSchema requires integer",
         "catalog lookup of clip.move.paramsSchema, then params.startTicks.type")

    # 8. params missing required field
    e = envelope(3008, user, "clip.move", {"trackId": "trk_drums", "startTicks": 960}, good_move_inverse)
    emit("params_missing_required.json", e, "params is missing clip.move's required 'clipId'",
         "catalog lookup of clip.move.paramsSchema, then params.required")

    # 9. undoable command with null inverse (clip.move is undoable:true)
    e = envelope(3009, user, "clip.move", good_move_params, None)
    emit("undoable_missing_inverse.json", e, "clip.move is undoable:true in the catalog but inverse is null",
         "catalog cross-check: undoable==true requires inverse != null")

    # 10. non-undoable command with a non-null inverse (export.master is undoable:false)
    e = envelope(3010, user, "export.master", {"outputPath": "/tmp/x.wav", "format": "wav"},
                 {"name": "export.master", "params": {"outputPath": "/tmp/x.wav", "format": "wav"}})
    emit("nonundoable_has_inverse.json", e, "export.master is undoable:false in the catalog but inverse is non-null",
         "catalog cross-check: undoable==false requires inverse == null")

    # 11. additionalProperties violation (extra top-level field)
    e = envelope(3011, user, "clip.move", good_move_params, good_move_inverse)
    e["extraField"] = True
    emit("additional_properties_rejected.json", e, "envelope has an extra top-level field not in the schema",
         "commandEnvelope.additionalProperties")

    # 12. result.ok == false without an error object
    e = envelope(3012, user, "clip.move", good_move_params, good_move_inverse, ok=False)
    emit("result_ok_false_missing_error.json", e, "result.ok is false but result.error is absent",
         "resultRef.if/then: ok==false requires error")

    assert len(manifest) == 12, f"expected 12 invalid command fixtures, got {len(manifest)}"
    write_json(out_dir / "manifest.json", {"count": len(manifest), "fixtures": manifest})
    print(f"wrote {len(manifest)} invalid command fixtures to {out_dir}")


# ---------------------------------------------------------------------------
# fixtures/gen-protocol/: 3 request/response pairs
# ---------------------------------------------------------------------------

def write_gen_protocol_fixtures():
    out_dir = FIXTURES_DIR / "gen-protocol"

    generate_request = {
        "requestId": ulid(9101),
        "caption": "warm lofi hip hop, rain on a window, vinyl crackle, mellow rhodes",
        "lyrics": "",
        "durationSeconds": 120,
        "bpm": 84,
        "key": "D minor",
        "timeSig": "4",
        "seed": 42,
        "model": "acestep-v15-turbo",
        "steps": 8,
        "nVariants": 1,
    }
    generate_response = {"jobId": ulid(9101)}

    revise_request = {
        "requestId": ulid(9102),
        "sourceAudioRef": "clip_drums_1",
        "regionStartSeconds": 4,
        "regionEndSeconds": 6,
        "instruction": "bigger, more aggressive drums in this section",
        "scope": "drums",
        "seed": 7,
        "variants": 1,
    }
    revise_response = {"jobId": ulid(9102)}

    analyze_request = {
        "requestId": ulid(9103),
        "sourceAudioRef": "clip_bass_1",
        "mode": "full",
    }
    analyze_response = {
        "bpm": 92,
        "key": "D minor",
        "duration": 16,
        "downbeats": None,
        "loudnessLufs": None,
        "caption": "",
        "lyrics": "",
        "language": "",
        "timeSig": "",
    }

    pairs = {
        "generate": (generate_request, generate_response),
        "revise": (revise_request, revise_response),
        "analyze": (analyze_request, analyze_response),
    }
    for op, (req, resp) in pairs.items():
        write_json(out_dir / f"{op}.request.json", req)
        write_json(out_dir / f"{op}.response.json", resp)
    write_json(out_dir / "manifest.json", {
        "count": len(pairs),
        "pairs": [
            {"op": op, "request": f"{op}.request.json", "response": f"{op}.response.json"}
            for op in pairs
        ],
    })
    print(f"wrote {len(pairs)} gen-protocol request/response pairs to {out_dir}")


def main():
    write_project_fixtures()
    write_valid_commands()
    write_invalid_commands()
    write_gen_protocol_fixtures()
    print("done")


if __name__ == "__main__":
    main()
