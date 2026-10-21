# timeline-core public interface (L1 guarantee)

L1 owns `engine/timeline-core/**`. This file is the API other lanes (L2 render
first) may build against. Everything listed here is additive-stable for Phase 1:
fields and methods may be ADDED, nothing listed is renamed, removed, or
retyped. A breaking change is a written proposal to the coordinating session,
never a silent edit.

## 1. Frozen P0-B surface (render already compiles against this)

- `Project { sample_rate: u32, tempo: TempoMap, sources: Vec<Source>, tracks: Vec<Track> }`
  plus `Project::new(sample_rate, tempo)`, `add_source`, `source`, `track`,
  `track_mut`, `track_index`, `find_clip`, `clip`, `clip_id_exists`,
  `content_end_frame`.
- `Track { id, name, mute, clips }`, `Track::new(id, name)`.
- `Clip { id, source_id, start_frame, offset_frames, len_frames, gain_db: f32,
  fade_in_frames, fade_out_frames, fade_shape: FadeShape }`, `Clip::end_frame()`.
- `Source { id, path, len_frames }` (field set FROZEN: render constructs it as a
  struct literal).
- `TempoMap` (`single`, `segments`, `tick_to_frame`, `frame_to_tick`,
  `bar_to_tick`, `beat_to_tick`), `Bpm`, `PPQ = 960`.
- Legacy command subset `Command` (P0-B variants and their exact fields),
  `Applied`, `TrimEdge`, `FadeShape { Linear, EqualPower }`, `CommandError`
  (existing variants), `Project::apply(&Command)`.
  Status: compatibility shim for render's current host/tests. New work goes
  through the catalog bus (section 3). The legacy path keeps the tick-canonical
  fields (section 2) in sync by deriving ticks from frames.

## 2. Schedule view (what L2 reads to compile a session)

Position model: catalog commands and persistence speak integer ticks (960 PPQ);
the model MATERIALIZES sample-frame fields through the tempo map on every
mutation (including `project.setTempo`, which re-derives every frame field from
ticks). Render keeps reading the frame fields it reads today; they are always
in sync with the tick fields.

Additive fields now on the model (all public, read-only for other lanes).
FINAL shipped types (v0.2). Every optional-in-command field is CONCRETE with a
canonical default in the model, never an `Option` "unset", so undo is exact
(back-to-default == never-set) and checkpoints omit defaults:

- `Clip`: `start_ticks`, `length_ticks`, `source_offset_ticks: u64` (canonical),
  `name: String` (defaults to the clip id; `display_name()`), `muted: bool`,
  `gain: Num` (wire-exact dB; `gain_db: f32` stays synced for render),
  `fade_in: FadeSpec`, `fade_out: FadeSpec` (`{ length_ticks, curve: FadeCurve }`;
  legacy `fade_*_frames`/`fade_shape` stay synced; `Exponential`/`Logarithmic`
  map to `FadeShape::EqualPower` until L2 consumes `FadeCurve`), `warp: Warp`
  (`{ mode: WarpMode, stretch_ratio: Num }`; default unwarped = `Ratio` at 1.0;
  `warp.is_unwarped()`), `offline: bool` (set at package open when the asset is
  absent under `audio/`, NOT by the pure executor), `asset_hash()` (= `source_id`),
  `end_ticks()`.
- `Track`: `color: String` (default `#FFFFFF`), `height_px: u32` (default 90),
  `solo: bool`, `armed: bool`, `gain: Num`, `pan: Num`, `sends: Sends { a, b: Num }`,
  `eq: [EqBand; 4]` (`{ freq_hz, gain_db, q: Num }`), `automation: Automation
  { volume, pan: Vec<AutoPoint> }`.
- `Project`: `bpm_wire: Num` (wire-exact tempo), `project_id`, `name`,
  `key: String`, `time_sig: TimeSig`, `sections: Vec<Section>`,
  `markers: Vec<Marker>`, `master: MasterBus`, `crossfades: Vec<Crossfade>`
  (active only while the two clips stay butt-joined on one track;
  `crossfade_is_active()`), `takes: Vec<TakeRecord>`.
- `Num` wraps `serde_json::Number` (preserves integer vs float exactly as it
  arrived on the wire; `as_f64()` for DSP use).
- Same-track clips never overlap (validated on every mutation); crossfades are
  metadata across a shared clip edge, not an overlap.

Stability note vs the first-hour draft: `warp` shipped as `Warp` (not
`Option<Warp>`) and `color`/`height_px` shipped concrete (not `Option`) so that
undo is bit-exact. Render's consumed surface (`start_frame`, `len_frames`,
`offset_frames`, `gain_db`, `fade_*_frames`, `fade_shape`) is unchanged, so this
refinement did not break L2.

## 3. Command entry (the real bus)

- `Cmd`: one typed variant per catalog command (71, names and params exactly
  `engine/contracts/command-catalog.v1.json`). Wire form:
  `{"name": "...", "params": {...}}` via serde.
- `Session`: owns `Project` + journal chain + txn state + undo/redo.
  - `Session::new(project)`, `Session::with_sink(project, Box<dyn JournalSink>)`.
  - `submit(&mut self, meta: EntryMeta, cmd: Cmd) -> Result<Submitted, CommandError>`
    validates (catalog paramsSchema + semantic), journals (write-ahead, hash
    chained), then applies. A failed command never partially applies and is not
    journaled. `submit_json(meta, name, params)` is the untyped wire entry.
  - `meta = EntryMeta { id: ulid string, ts: UTC string, actor: Actor }` is
    caller-supplied (core reads no clock).
  - `txn.begin`/`txn.commit` submitted like any command; commands between them
    form one undo unit (v1: no nesting; abort_txn() rolls the open unit back).
  - `undo(meta_source) / redo(meta_source)`: inverse application journaled
    FORWARD (history never rewrites); multi-command units journal inside a txn
    bracket. Idempotency: a command id already in the journal is acknowledged,
    not re-applied.
  - `project(&self) -> &Project` for direct compile (L2 keeps using this).
  - `undo` / `redo` take `&mut dyn MetaSource` (the app supplies fresh ULIDs +
    timestamps for the journaled-forward entries). `SeqMeta` is a deterministic
    MetaSource for tests/dev.
  - `replay(base, envelopes)` and `resume(base, envelopes, already_applied)`
    rebuild a Session from a journal (resume skips a checkpoint prefix already
    reflected in `base`, used by fast-open).
- Errors: `CommandError` is a typed enum with a stable `code()` string
  (documented in `error.rs`).

## 4. Snapshot + diff-cursor (UI / FFI / MCP readers)

- `snapshot(&mut self) -> Snapshot`: cheap immutable snapshot (`Arc<Project>` +
  `seq`); cached until the next mutation, so cost is one clone per mutated
  frame at most.
- `seq(&self) -> u64`: journaled entry count (monotone).
- `changes_since(&self, seq) -> Changes`: `None` (nothing changed),
  `Delta(Vec<ChangeScope>)` when the window (512 entries) still covers `seq`,
  else `Resync` (adopt a full snapshot).

## 5. Journal + package io

- `Envelope` per contracts `commandEnvelope`; canonicalization + blake3 chain
  per `engine/contracts/README.md`, byte-identical to `contracts-conformance`
  (a dev test cross-checks it, and the P0-C fixture journal verifies against my
  hashing and lands on the golden tipHash). Envelope `inverse` carries the
  catalog-declared single-command hint; the runtime inverse used by undo
  restores full state.
- `JournalSink` trait (append + sync): the native `FileJournal` lives behind
  `#[cfg(not(target_arch = "wasm32"))]`; wasm/tests use `MemoryJournal`.
- `Package` (native, cfg-gated): `Package::create/save/open(dir, ...)` for
  `.mstudio`. Save is crash-safe: journal rewritten + fsynced first, then the
  new checkpoint written to a tmp, fsynced, atomically renamed, dir fsynced.
  Open verifies the whole chain, takes the checkpoint fast-path when it matches
  a chain prefix (else full replay from empty), and marks clips whose asset is
  absent under `audio/` as `offline`; unknown JSON fields round-trip. Per-track
  EQ is persisted under the first-class `eq` key (catalog v2 accepted deferred
  proposal 2; ParamRef has to address `track.eq.<band>.<gain|freq|q>`, so EQ
  cannot stay implicit). The v1 namespaced `engineEq` key is still READ, so
  older checkpoints load unchanged; it is no longer written.

## 6. wasm discipline

The crate compiles for `wasm32-unknown-unknown` (`ci-check.sh` here runs the
same check `engine/run-tests.sh` runs). No fs, no threads, no OS clock in core
paths; all io behind the traits above.
