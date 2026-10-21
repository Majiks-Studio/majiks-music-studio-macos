# engine/media mapping note

Lane L3's session brief (file-ownership rule) requires this crate to ship
standalone types plus a mapping note rather than depend on `timeline-core`
or `engine/contracts`, even though both are already merged. This file is
that note, and it also records the one deliberate decision this lane made
that a later merge step should confirm or override: **not** taking a Rust
dependency on `timeline-core`, on purpose, explained below.

## 1. Why `engine/media` does not depend on `timeline-core`

`timeline-core::tempo::TempoMap`/`Bpm` model tempo as an exact rational
(`num`/`den`) anchored to 960-PPQ integer ticks -- the right representation
for the command bus and the render engine's sample-accurate scheduling.
This crate's tempo estimate is fundamentally a **continuous-time
measurement** (seconds, from audio), not a symbolic tick position, so the
two types are not the same thing wearing different clothes; converting one
to the other is a real decision (rounding precision, where tick 0 lands
relative to the measured first beat) that belongs to whoever owns the
project's tempo map, not to the analysis step that produces a prior for it.

Concretely, taking a `path = "../timeline-core"` dependency was
technically available (it is already merged, per the general brief's
"consume their types only if already merged" guidance) but was rejected
for three reasons, offered here as a proposal the coordinator can override:

1. **wasm32 minimality.** This crate's pure-math surface (tempo, key,
   waveform peaks) is required to compile for `wasm32-unknown-unknown`.
   `timeline-core` also claims wasm32-compilability, but pulling in its
   command bus / model / journal surface for what is otherwise a ~4-struct
   DTO dependency (`TempoMapEstimate`, `KeyEstimate`, `PeakPair`,
   `LoudnessEstimate`) widens this crate's wasm build surface for no
   analysis-side benefit.
2. **Parallel-lane merge safety.** L1 owns `timeline-core` and may still be
   iterating on it in parallel with this lane. A hard dependency would
   couple `engine/media`'s ability to compile to `timeline-core`'s exact
   state at every commit, which the file-ownership rule (each lane owns its
   own files, coordinator merges) is explicitly designed to avoid.
3. **The conversion is lossy and policy-bearing, not mechanical.** See
   section 2: rounding a measured f64 BPM into a `num/den` rational, and
   deciding what tick the measured first beat lands on, are both product
   decisions (how much precision matters, whether a clip's tick-0 is
   defined by import time or by the measured downbeat) that this lane has
   no basis to make unilaterally.

If the coordinator prefers a real dependency instead of this note, the
conversion functions in section 2 are the ones to lift into either crate.

## 2. `TempoMapEstimate` -> `timeline-core::tempo::{Bpm, TempoMap}`

`tempo::TempoMapEstimate` (this crate):

```rust
pub struct TempoMapEstimate {
    pub bpm: f64,               // measured, continuous
    pub confidence: f64,
    pub first_beat_offset: f64, // seconds from t=0 to the first tracked beat
    pub downbeats: Vec<f64>,    // seconds
    pub beats: Vec<f64>,        // seconds
    pub time_signature: String, // always "4/4" in v1
    pub declared_bpm_hint_used: bool,
}
```

Suggested conversion, once a consumer wants a `timeline_core::tempo::Bpm`:

```rust
// Round to 1/100 BPM: timeline-core's Bpm is an exact rational, so pick a
// denominator that comfortably exceeds this crate's own measurement
// precision (well inside the golden tests' +/-0.5 BPM bar) rather than
// trying to represent an f64 exactly.
let num = (estimate.bpm * 100.0).round() as u32;
let bpm = timeline_core::tempo::Bpm::new(num, 100)?;
let tempo_map = timeline_core::tempo::TempoMap::single(bpm);
```

`first_beat_offset` and `downbeats` do NOT have a mechanical mapping onto
`TempoMap` ticks: `TempoMap` has no concept of "where in a clip's audio the
first beat falls," because that is a property of a *placed clip* (which
sample of the imported audio asset lands on which tick), not of the tempo
map itself. That placement decision belongs to whatever command handles
`import.audio` / `clip.place` (command catalog v1, 02-ARCHITECTURE.md
section 4) -- this crate's job stops at handing over an honest measurement
in seconds; deciding how an import wizard uses it (snap-to-grid on import?
warn if it disagrees with the project tempo by more than X%? leave the clip
off-grid until the user asks to conform it?) is a product question for L1
or L5, called out here rather than guessed at.

## 3. `AnalyzeReport` -> Gen Protocol `analyzeResponse`

`engine/contracts/gen-protocol.schemas.json`'s `analyzeResponse` has five
fields relevant here: `bpm`, `key`, `duration`, `downbeats`, `loudnessLufs`
(all nullable; `caption`/`lyrics`/`language`/`timeSig`/`genre`/`style` are
Python-backend-only and have no equivalent here).
`gen-protocol-mapping.md`'s "analyze" section already documents that
`downbeats` and `loudnessLufs` are gap fields owned by this crate ("Planned
to live in the Rust engine's `media` crate ... not in the Python backend at
all").

`types::AnalyzeReport` is `#[serde(rename_all = "camelCase")]` and its
first five fields are named and typed to serialize identically to
`analyzeResponse`'s five fields:

| `AnalyzeReport` field (Rust) | JSON key       | `analyzeResponse` field |
|---|---|---|
| `bpm: Option<f64>`           | `bpm`          | `bpm` (measured, not declared -- see `tempo` module docs) |
| `key: Option<String>`        | `key`          | `key` (`"<tonic> <major\|minor>"`, e.g. `"D minor"`) |
| `duration: Option<f64>`      | `duration`     | `duration` |
| `downbeats: Option<Vec<f64>>`| `downbeats`    | `downbeats` (seconds) |
| `loudness_lufs: Option<f64>` | `loudnessLufs` | `loudnessLufs` |

Checked by `tests/gen_protocol_field_parity.rs` (hardcodes the five names
since this crate does not depend on `engine/contracts`; if `analyzeResponse`
changes at the next contract revision, that test is the one to update).

A caller that wants the exact `analyzeResponse` shape can serialize
`AnalyzeReport` and keep only those five keys; everything else on
`AnalyzeReport` (`contentHash`, `sampleRate`, `truePeakDbtp`, the full
`tempo`/`keyEstimate` objects, `declaredBpm`/`declaredVsMeasuredPct`) is
this crate's richer native shape, additive and ignorable.

## 4. `render::rt::ENGINE_SAMPLE_RATE`

`report::ENGINE_SAMPLE_RATE_HINT = 48_000` mirrors
`engine/render/src/rt.rs::ENGINE_SAMPLE_RATE` by VALUE, not by dependency
(same reasoning as section 1: `render` pulls in `cpal`/real-time audio I/O,
which this crate has no reason to depend on for a constant). If the engine
rate ever changes, both constants need updating; there is exactly one other
place this matters today (`engine/render/src/media.rs`'s own
`ENGINE_SAMPLE_RATE` use), so a repo-wide grep for `48_000` /
`ENGINE_SAMPLE_RATE` at that point will find both.

## 5. What changes at merge (for the coordinator)

1. Add `"media"` to `engine/Cargo.toml`'s `members` list.
2. Nothing in `engine/media`'s own source needs to change: its
   `[workspace]` table is only load-bearing while it is NOT a member (it
   makes Cargo stop searching upward for a workspace); once it is listed in
   the parent's `members`, the parent's workspace resolution takes over and
   this crate's own `[workspace]` table becomes redundant but harmless
   (Cargo allows a workspace member to also declare an empty `[workspace]`
   table -- it is equivalent to omitting it once the parent lists the
   member). Leaving it in place costs nothing and keeps this crate buildable
   standalone if it is ever extracted again.
3. `engine/media/.cargo/config.toml`'s `target-dir = "../target"` becomes
   unnecessary (everyone already shares `engine/target` once `media` is a
   real workspace member) but is also harmless to leave; deleting it is a
   one-line cleanup, not a functional change.
4. Optional follow-up, not required: if the coordinator prefers a real
   `timeline-core` dependency over the conversion note in section 2, lift
   `Bpm`/`TempoMap` construction out of section 2's snippet into either
   crate.
