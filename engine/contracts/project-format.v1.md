# .mstudio project package v1

Source of truth for the machine-checkable shape: `project.schema.json` (the
`project.json` checkpoint) and `command-catalog.schema.json`'s `commandEnvelope`
`$def` (each `journal.jsonl` line). This document is the prose walkthrough plus a
worked example; where it and the schemas disagree, the schemas are authoritative
and this file is out of date.

## Package layout

```
Song Title.mstudio/            directory package; FileWrapper on Mac
  project.json                 schema-versioned model snapshot (fast open)
  journal.jsonl                hash-chained command log (truth; replay = recovery)
  audio/                       imported + landed assets, content-addressed names
  takes/                       generative variants (kept until user purges)
  tiles/                       waveform tile cache (rebuildable, gitignored-class)
  manifest.json                provenance summary (rebuildable from journal)
```

- `project.json` is a **checkpoint** of the journal, not a second source of
  truth. It exists so opening a project is O(1) in journal length instead of a
  full replay every time. Every field in it is, in principle, derivable by
  replaying `journal.jsonl` from empty; the `journal` block inside it (see
  below) is what makes that claim checkable rather than asserted.
- `journal.jsonl` is append-only and hash-chained. It is the provenance event
  log: export manifests and per-clip lineage trees are views over it plus asset
  content hashes (02-ARCH section 4). Undo/redo append new inverse entries; the
  journal never rewrites history (the DJ `StemOriginOp` lesson referenced in
  02-ARCH section 3).
- `audio/` and `takes/` are both content-addressed by blake3: a file's name is
  (or embeds) its hash, so two clips referencing identical audio share storage
  and a `clip.place` command only needs to carry the hash, not a path.
- `tiles/` is a cache: safe to delete, rebuilt from `audio/` on demand.
- `manifest.json` is a rebuildable summary view over the journal (see
  `export.manifest` in `command-catalog.v1.json`), not authoritative on its own.

## project.json is a checkpoint, not a parallel truth

Every save writes `project.json` as of the current journal tip, then marks
journal segments prior to that tip eligible for truncation once the write is
confirmed durable on disk. Older segments are kept until the new checkpoint
write succeeds, so a crash mid-save cannot lose data: worst case, the next open
replays a bit more journal than strictly necessary.

To make "this checkpoint matches this journal" a checkable fact rather than an
assumption, `project.json` carries a `journal` block:

```json
"journal": {
  "entryCount": 30,
  "tipId": "01J8Z4G9K2X4Q6R8T0V2W4Y6A8",
  "tipHash": "b2f1...(64 hex chars)...",
  "genesisHash": "0000000000000000000000000000000000000000000000000000000000000000000000000000",
  "checkpointedAt": "2026-07-11T20:07:03Z"
}
```

`entryCount` and `tipHash` must match what you get from independently replaying
`journal.jsonl`'s hash chain (see README.md, "Canonicalization and the hash
chain"). Conformance tooling in both languages checks exactly this: it is not a
full semantic replay of every command (that is timeline-core's job, out of scope
for this contracts-only lane), it is proof that the checkpoint's pointer into
the journal is internally consistent. `fixtures/project/minimal-journal.jsonl`
is 30 real, hand-traced commands; `fixtures/project/minimal-project.json`'s
`tracks`/`clips`/`sections` content is what those 30 commands produce, authored
by reading each command's effect in `command-catalog.v1.json`, so the fixture is
useful as a golden test for a future lane's real command executor too, even
though this lane's own conformance check only verifies the hash-chain/pointer
invariant, not the full state derivation.

## Asset resolution and offline clips

Every clip references its audio by `assetHash` (blake3 of the file under
`audio/`), never by a path. Opening a project that is missing an asset (moved,
never synced, external drive unplugged) degrades that one clip to `offline:
true` with the project otherwise usable — never a hard refusal to open the
whole package (02-ARCH section 6).

## Forward compatibility

`project.schema.json` sets `additionalProperties: true` everywhere, on purpose,
unlike `command-catalog.schema.json`'s envelope (which is strict). A project
file is long-lived and gets opened by whichever app version is installed;
`journal.jsonl` command names are versioned by the catalog and validated
strictly at apply-time, but the checkpoint format must round-trip fields a
newer app wrote and an older app does not understand. The schema constrains the
*type* of every field it knows about and never rejects a document for carrying
an extra one.

## Worked example

A brand-new project, three commands in:

1. `project.new {"name": "Late Night Drive"}` (unjournaled, lifecycle)
2. `project.setTempo {"bpm": 92}` (journaled, entry 1)
3. `track.add {"trackId": "trk_drums", "name": "Drums", "index": 0}` (journaled, entry 2)

`journal.jsonl` (two lines, matching entry 1 and entry 2 above; canonicalization
of the hashed payload is defined in README.md):

```json
{"id":"01J8Z4G9K0000000000000001","ts":"2026-07-11T20:04:01Z","actor":{"kind":"user","name":"aaron"},"name":"project.setTempo","params":{"bpm":92},"inverse":{"name":"project.setTempo","params":{"bpm":120}},"result":{"ok":true},"hash":"<blake3 hex>"}
{"id":"01J8Z4G9K0000000000000002","ts":"2026-07-11T20:04:07Z","actor":{"kind":"user","name":"aaron"},"name":"track.add","params":{"trackId":"trk_drums","name":"Drums","index":0},"inverse":{"name":"track.remove","params":{"trackId":"trk_drums"}},"result":{"ok":true},"hash":"<blake3 hex>"}
```

The corresponding `project.json` after a save at this point (abbreviated):

```json
{
  "formatVersion": 1,
  "projectId": "01J8Z4G9K0PROJECT00000000",
  "name": "Late Night Drive",
  "tempo": { "bpm": 92 },
  "timeSig": { "numerator": 4, "denominator": 4 },
  "sampleRateHz": 48000,
  "ppq": 960,
  "tracks": [
    { "trackId": "trk_drums", "name": "Drums", "index": 0, "muted": false, "soloed": false, "gainDb": 0, "pan": 0 }
  ],
  "clips": [],
  "journal": {
    "entryCount": 2,
    "tipId": "01J8Z4G9K0000000000000002",
    "tipHash": "<blake3 hex of entry 2, chained from entry 1's hash>",
    "genesisHash": "0000000000000000000000000000000000000000000000000000000000000000000000000000",
    "checkpointedAt": "2026-07-11T20:04:10Z"
  }
}
```

`fixtures/project/minimal-project.json` and
`fixtures/project/minimal-journal.jsonl` extend this same pattern to 30 journal
entries across project/track/clip/marker/automation/mixer commands, with the
full hand-traced state and real computed hashes; the two-command version above
is kept small enough to read in one sitting.
