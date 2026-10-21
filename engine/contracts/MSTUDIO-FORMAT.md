# The .mstudio project format

An `.mstudio` project is a directory package. It holds a fast-open checkpoint
(`project.json`) plus an append-only, blake3 hash-chained command journal
(`journal.jsonl`) that is the source of truth. Replaying the journal from empty
reproduces the checkpoint. The journal also serves as the undo log and the
provenance event log for export manifests and clip lineage.

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

- `project.json` is a checkpoint of the journal, not a second source of truth.
  It exists so opening a project is O(1) in journal length.
- `journal.jsonl` is append-only and hash-chained. It is the provenance event
  log. Undo and redo append new inverse entries; the journal never rewrites
  history.
- `audio/` and `takes/` are both content-addressed by blake3: a file name is
  (or embeds) its hash.
- `tiles/` is a cache. Safe to delete; rebuilt from `audio/` on demand.
- `manifest.json` is a rebuildable summary view over the journal. It is not
  authoritative on its own.

## project.json (the checkpoint)

`project.json` carries the `journal` block so that "this checkpoint matches
this journal" is a checkable fact rather than an assertion. Every save writes
`project.json` as of the current journal tip, then marks journal segments prior
to that tip eligible for truncation once the write is confirmed durable on disk.

### Required fields

| Field           | Type   | Description                                                                 |
|-----------------|--------|-----------------------------------------------------------------------------|
| `formatVersion` | number | Must be `1`.                                                                |
| `projectId`     | string | Unique project identifier (min length 1).                                   |
| `name`          | string | Project name (min length 1).                                                |
| `tempo`         | object | Contains `bpm` (required, positive, max 999).                               |
| `timeSig`       | object | Contains `numerator` (1..32) and `denominator` (1, 2, 4, 8, 16, 32).        |
| `sampleRateHz`  | integer | `44100` or `48000`.                                                        |
| `ppq`           | number | Must be `960`. Beats are stored as rational integer ticks, not float.       |
| `tracks`        | array  | List of track objects (required, may be empty).                             |
| `clips`         | array  | List of clip objects (required, may be empty).                              |
| `journal`       | object | Pointer into `journal.jsonl` (required).                                    |

### Optional fields

| Field        | Type   | Description                                                           |
|--------------|--------|-----------------------------------------------------------------------|
| `key`        | string | Musical key of the project.                                           |
| `sections`   | array  | Project sections, each with `sectionId`, `name`, `startTicks`.        |
| `markers`    | array  | Timeline markers, each with `markerId`, `positionTicks`, `label`.     |
| `masterBus`  | object | Master bus with `gainDb` and optional `limiter`.                      |

### tempo

Required sub-fields: `bpm` (number, `exclusiveMinimum: 0`, `maximum: 999`).

### timeSig

Required sub-fields: `numerator` (integer, 1 to 32) and `denominator`
(integer, one of 1, 2, 4, 8, 16, 32).

### tracks

Each track object carries the required fields `trackId`, `name`, and `index`
(>= 0). Optional fields include `color`, `heightPx` (24..400), `muted`
(default false), `soloed` (default false), `armed` (default false),
`inputChannel` (default 0; the 0-based hardware input this track records from,
written by `track.setInputChannel`), `gainDb`
(default 0, range -60..12), `pan` (default 0, range -1..1), `sends`
(axes a and b, 0..1), and `automation` (arrays of automation points for
`volume` and `pan`).

### clips

Each clip object carries the required fields `clipId`, `trackId`, `assetHash`,
`startTicks`, and `lengthTicks` (positive). Clips reference audio by blake3
hash (`assetHash`), never by file path. Optional fields:

| Field                | Type    | Description                                              |
|----------------------|---------|----------------------------------------------------------|
| `name`               | string  | Clip display name.                                       |
| `sourceOffsetTicks`  | integer | Offset into the source audio (default 0).                |
| `gainDb`             | number  | Clip gain, -60 to 12 (default 0).                        |
| `muted`              | boolean | Muted state (default false).                             |
| `fadeIn`             | object  | Fade-in envelope (lengthTicks, shape).                   |
| `fadeOut`            | object  | Fade-out envelope (lengthTicks, shape).                  |
| `warp`               | object  | Time-stretch settings (`mode: ratio | conform`, `stretchRatio`). |
| `offline`            | boolean | True when the asset was missing at open time (default false). |

A clip is marked `offline: true` when `assetHash` cannot be resolved under
`audio/` at open time. The project still opens; only that clip degrades.

### sections

Each section object carries the required fields `sectionId`, `name`, and
`startTicks` (>= 0). Optional field: `color` (hex, `^#[0-9A-Fa-f]{6}$`).

### markers

Each marker object carries the required fields `markerId`, `positionTicks`
(>= 0), and `label`. Optional field: `color` (hex, `^#[0-9A-Fa-f]{6}$`).

### masterBus

Optional top-level object. Carries `gainDb` (-60 to 12, default 0) and an
optional `limiter` sub-object with `enabled` (boolean), `ceilingDb`
(-6 to 0), and `releaseMs` (1 to 1000).

### journal

This block pins the checkpoint to `journal.jsonl`. Required fields:

| Field            | Type   | Description                                                                 |
|------------------|--------|-----------------------------------------------------------------------------|
| `entryCount`     | integer| Total entries in `journal.jsonl` (>= 0).                                    |
| `tipHash`        | string | 64-char hex blake3 hash of the last journal entry.                          |
| `genesisHash`    | string | Always 64 zero characters in v1.                                            |

Optional fields:

| Field            | Type   | Description                                                               |
|------------------|--------|---------------------------------------------------------------------------|
| `tipId`          | string | ID of the last journal entry (null when entryCount is 0).                 |
| `checkpointedAt` | string | ISO 8601 timestamp of the last checkpoint write.                          |

Conformance tooling recomputes the hash chain over `journal.jsonl` and requires
`entryCount` and `tipHash` to match exactly.

### Schema behavior

The schema sets `additionalProperties: true` everywhere. This allows a newer
app to write fields that an older app does not understand, preserving them on
round-trip. The schema constrains the type of every field it knows about but
never rejects a document for carrying extra ones.

## journal.jsonl (the source of truth)

`journal.jsonl` is an append-only, blake3 hash-chained command log. Each line
is a single JSON object (a command envelope). Replaying all entries from empty
reproduces the `project.json` checkpoint. The journal is the provenance event
log: export manifests and per-clip lineage trees are views derived from it plus
asset content hashes. Undo and redo do not rewrite history; they append new
inverse entries.

### Command envelope

Every journal line carries these fields:

| Field      | Type   | Description                                                             |
|------------|--------|-------------------------------------------------------------------------|
| `id`       | string | Unique command ID.                                                      |
| `ts`       | string | ISO 8601 timestamp of the command.                                      |
| `actor`    | object | Who performed the command (e.g. `{"kind":"user","name":"aaron"}`).      |
| `name`     | string | Command name, e.g. `project.setTempo`, `track.add`.                     |
| `params`   | object | Command-specific parameters.                                            |
| `inverse`  | object | The inverse command for undo (name + params).                           |
| `result`   | object | Outcome, e.g. `{"ok": true}`.                                           |
| `hash`     | string | 64-char hex blake3 hash of this entry, chaining from the previous entry.|

### The blake3 hash chain

Each entry's `hash` is the blake3 digest of that entry, chained from the
previous entry. The `genesisHash` field in `project.json` is always 64 zero
characters. The chain starts from the genesis hash, and each subsequent entry
hashes the prior entry's hash as its chain seed.

### Replay

To reconstruct the project state from the journal: start with an empty project
and apply every command in `journal.jsonl` in order. The resulting state must
match `project.json`. Conformance tooling checks the hash chain (entryCount and
tipHash) but does not perform a full semantic replay.

### Undo and redo

Undo and redo append forward. An undo appends the inverse command recorded in
each entry's `inverse` field. A redo reapplies the original command. The
journal never rewrites or deletes history.

## Crash safety and forward compatibility

### Crash safety

Every save writes `project.json` as of the current journal tip, then marks
journal segments prior to that tip eligible for truncation once the write is
confirmed durable on disk. Older segments are kept until the new checkpoint
write succeeds, so a crash mid-save cannot lose data. The worst case is that
the next open replays a bit more journal than strictly necessary.

### Forward compatibility

`project.schema.json` sets `additionalProperties: true` everywhere. A project
file is long-lived and gets opened by whichever app version is installed.
`journal.jsonl` command names are versioned by the catalog and validated
strictly at apply-time, but the checkpoint format must round-trip fields a
newer app wrote and an older app does not understand. The schema constrains
the type of every field it knows about and never rejects a document for
carrying an extra one.

### Missing assets

Opening a project that is missing an asset (moved, never synced, external
drive unplugged) degrades that one clip to `offline: true` with the project
otherwise usable. The app never refuses to open the whole package because one
clip is offline.
