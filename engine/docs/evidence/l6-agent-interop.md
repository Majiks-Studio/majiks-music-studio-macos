# L6 agent interop transcript (acceptance)

A single hands-free run of `majiks-studio-cli interop` builds a project entirely
through the timeline-core command bus, saves the `.mstudio`, and bounces a WAV.
Every step is a catalog command; no UI, no human input. The run also proves the
two agent-facing routes (raw envelopes via `ffi_studio_command`/CLI, and named
tools via the MCP server/copilot) bounce **bit-identically**.

Reproduce:

```
cargo run -p agent-surface --bin majiks-studio-cli -- interop --dir /tmp/l6-evidence
```

## Transcript

```
== interop: build a project hands-free through the command bus ==
  project.setTempo -> {"command":"project.setTempo","duplicate":false,"journaled":true,"mutated":true,"ok":true,"seq":1}
  track.add -> {"command":"track.add","duplicate":false,"journaled":true,"mutated":true,"ok":true,"seq":2}
  track.add -> {"command":"track.add","duplicate":false,"journaled":true,"mutated":true,"ok":true,"seq":3}
  import.audio -> {"assetHash":"cb7f32883d5bb5575a38d4094af0ff79f457bb3cec757adac9286a9011189c14","clipId":"c1","lengthTicks":15360,"ok":true,"seq":4,"startTicks":0,"trackId":"t1"}
  import.audio -> {"assetHash":"f77acae4c776515d885cc61ded8d21f09fce305f94b04bb4b8b6102b6395c331","clipId":"c2","lengthTicks":7680,"ok":true,"seq":5,"startTicks":7680,"trackId":"t2"}
  clip.move -> {"command":"clip.move","duplicate":false,"journaled":true,"mutated":true,"ok":true,"seq":6}
  clip.trim -> {"command":"clip.trim","duplicate":false,"journaled":true,"mutated":true,"ok":true,"seq":7}
  project.save -> {"ok":true,"seq":7}
  export.master -> {"frames":408000,"ok":true,"outputPath":"/tmp/l6-evidence/Interop-master.wav","peak":1.028533935546875,"sampleRateHz":48000,"seconds":8.5}

== null match: envelope route vs tool route ==
  envelope 408000 frames vs tool 408000 frames: peak -inf dBFS, bit_identical=true

interop: PASS
```

What the CLI actually did, in order: created `Interop.mstudio`, set tempo 120,
added tracks `t1`/`t2`, imported two engine testdata fixtures
(`click_120bpm_48k_stereo.wav`, `tone_440_48k_mono.wav`) as content-addressed
clips `c1`/`c2` (io + a journaled `clip.place`), moved `c2` from bar 2 to bar 1
(7680 -> 3840 ticks), trimmed `c1`'s end by one beat (-960 ticks: 15360 ->
14400), saved the package, and bounced the master (408000 frames, 8.5 s).

The FFI-vs-CLI bit-identical bounce is proven separately by
`tests/interop.rs::cli_bounce_null_matches_ffi_bounce_bit_identical`.

## Resulting project checkpoint (`project.json`)

```json
{
  "clips": [
    { "assetHash": "cb7f...9c14", "clipId": "c1", "lengthTicks": 14400, "startTicks": 0, "trackId": "t1" },
    { "assetHash": "f77a...c331", "clipId": "c2", "lengthTicks": 7680, "startTicks": 3840, "trackId": "t2" }
  ],
  "formatVersion": 1,
  "journal": { "entryCount": 7, "tipHash": "dfaa...4350", "tipId": "01KXAAQAZ6EMWEYRFZ325TC8WF" },
  "name": "Interop Demo",
  "ppq": 960,
  "projectId": "01KXAAQARAJBMEK6VW19KKHHX9",
  "sampleRateHz": 48000,
  "tempo": { "bpm": 120 },
  "timeSig": { "denominator": 4, "numerator": 4 },
  "tracks": [
    { "index": 0, "name": "Drums", "trackId": "t1" },
    { "index": 1, "name": "Bass", "trackId": "t2" }
  ]
}
```

The `.mstudio` also contains `audio/<blake3>.wav` for each imported clip and a
hash-chained `journal.jsonl` (7 entries). The audio blobs and the bounce WAV are
NOT committed (binary); the text checkpoint + journal are the evidence.

## Journal (`journal.jsonl`, hash-chained, real ULIDs)

```jsonl
{"actor":{"kind":"agent","name":"sarge"},"hash":"8892...13f8","id":"01KXAAQARMFFEHVYSMM1HW8QCW","inverse":{"name":"project.setTempo","params":{"bpm":120}},"name":"project.setTempo","params":{"bpm":120},"result":{"ok":true},"ts":"2026-07-12T04:52:44Z"}
{"actor":{"kind":"agent","name":"sarge"},"hash":"8fab...89dd","id":"01KXAAQARQ51685D7S17Q38KFY","inverse":{"name":"track.remove","params":{"trackId":"t1"}},"name":"track.add","params":{"name":"Drums","trackId":"t1"},"result":{"ok":true},"ts":"2026-07-12T04:52:44Z"}
{"actor":{"kind":"agent","name":"sarge"},"hash":"1351...b386","id":"01KXAAQARQSS2SCEFFAQQ1KM8B","inverse":{"name":"track.remove","params":{"trackId":"t2"}},"name":"track.add","params":{"name":"Bass","trackId":"t2"},"result":{"ok":true},"ts":"2026-07-12T04:52:44Z"}
{"actor":{"kind":"user","name":"import"},"hash":"d558...a299","id":"01KXAAQAXR7GHH984R3CKJN8SW","inverse":{"name":"clip.remove","params":{"clipId":"c1"}},"name":"clip.place","params":{"assetHash":"cb7f...9c14","clipId":"c1","lengthTicks":15360,"startTicks":0,"trackId":"t1"},"result":{"ok":true},"ts":"2026-07-12T04:52:44Z"}
{"actor":{"kind":"user","name":"import"},"hash":"351c...3330","id":"01KXAAQAZ6X35S4CHKXVEGXYDV","inverse":{"name":"clip.remove","params":{"clipId":"c2"}},"name":"clip.place","params":{"assetHash":"f77a...c331","clipId":"c2","lengthTicks":7680,"startTicks":7680,"trackId":"t2"},"result":{"ok":true},"ts":"2026-07-12T04:52:44Z"}
{"actor":{"kind":"agent","name":"sarge"},"hash":"a538...5922","id":"01KXAAQAZ6A1PKEFZC0YQ7N0Z3","inverse":{"name":"clip.move","params":{"clipId":"c2","startTicks":7680,"trackId":"t2"}},"name":"clip.move","params":{"clipId":"c2","startTicks":3840,"trackId":"t2"},"result":{"ok":true},"ts":"2026-07-12T04:52:44Z"}
{"actor":{"kind":"agent","name":"sarge"},"hash":"dfaa...4350","id":"01KXAAQAZ6EMWEYRFZ325TC8WF","inverse":{"name":"clip.trim","params":{"clipId":"c1","deltaTicks":960,"edge":"end"}},"name":"clip.trim","params":{"clipId":"c1","deltaTicks":-960,"edge":"end"},"result":{"ok":true},"ts":"2026-07-12T04:52:44Z"}
```

Note the `import.audio` decomposition: the agent asked to import a file; the host
did the io (decode + blake3 + copy into `audio/`) and journaled a single
`clip.place` carrying the real asset hash + length, so replay is deterministic
without re-reading the source file (see the L6 report proposal).
