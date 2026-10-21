# E1 + E2 — MIDI notes, piano roll, software instruments

**Status:** seam spec, locked before implementation · **Epics:** P-00122 E1 (`97ba93d1`) · E2 (`f88d3180`)
**Depends on:** E0 (`DESIGN-catalog-v2.md`) — landed. Catalog v2, `ParamRef`, dense lane table, routing DAG model.

This document exists for ONE reason: three lanes run in parallel, and they must agree on the
seams **before** they write code. Everything below is a decision, not a suggestion. If a lane
believes a decision is wrong, it reports and stops on that point rather than substituting its own.

---

## 0. What E0 already gives us (verified in-tree — do not rebuild)

| Asset | Where | E1/E2 use |
|---|---|---|
| `ParamRef::TrackDeviceParam { device_id, param }` | `timeline-core/src/paramref.rs:119,163` | **Instrument params are already addressable and automatable. E2 needs NO contract work for automation.** |
| Dense preallocated lane table, `ParamRef → slot` | `RtTrack.lanes`, `RtSession.lane_index`, resolved in `compile.rs` | Instrument params automate through the same path as volume/pan. |
| Catalog v2 (93 cmds), additive, superset-tested | `contracts/command-catalog.v2.json` | E1/E2 ADD commands here. |
| Routing DAG model + topo sort | `timeline-core/src/routing.rs` | An instrument is a node; E5 evaluates. |

**Catalog v2 additions are governed by E0 §9.2 (HARD RULE): new semantics go in NEW command
names. NEVER add an optional param to an existing v1.1 command** — replay does not validate
params and nothing uses `deny_unknown_fields`, so an older binary would verify the chain and
silently build a wrong model. Also: never touch `ENVELOPE_HASHED_FIELDS`.

---

## 1. Note model (E1 owns; E2 consumes)

Lives in `timeline-core` (wasm-clean leaf crate), journaled, undoable, `.mstudio`-serialized.

```rust
pub struct Note {
    pub id: String,              // ULID-shaped, stable identity for edit/undo
    pub start_ticks: u64,        // clip-relative, same rational tick domain as clips
    pub length_ticks: u64,       // > 0; zero-length is rejected at apply time
    pub pitch: u8,               // 0..=127, MIDI note number
    pub velocity: Num,           // 0..=127 on the wire, Num NOT f32 (see below)
    #[serde(default)] pub extra: Map<String, Value>,
}
```

**Non-negotiable:** `velocity` — and every note field that reaches the journal — is `Num`,
never `f32`/`f64` (E0 §1 invariant 6; `Num` preserves integer/float *shape*, which the hash
chain depends on). Give `Note` an `extra` map: every sibling struct has one, and E0 §9.3
showed that omitting it means a future field is **destroyed**, not merely ignored.

**Ordering must be total and deterministic** — `(start_ticks, pitch, id)`, mirroring
`Automation::sort_lane`'s `(position_ticks, id)`. Nondeterministic ordering changes serialized
bytes.

### MIDI clips
Notes live on a **clip**, not loose on a track, so all existing clip machinery (move, trim,
split, duplicate, fades-where-meaningful, lineage) composes. A clip becomes discriminated:
audio-backed or note-backed.

⚠️ **`Clip` is existing v1.1 law.** Adding a variant must not change how an existing audio
clip serializes. Prefer an additive optional field defaulting to audio over re-tagging the
enum. **Prove old projects still open** — extend `v1_1_replay_regression.rs`.

---

## 2. The note-event contract (THE SEAM — E1 produces, E2 consumes)

This is the interface the three lanes share. Get it right and the merge is trivial.

**Notes are baked control-side into the session snapshot, exactly like automation lanes.**
They are NOT streamed per-event through the command channel. This follows the established
pattern (`compile.rs` flattens `Project` → `RtSession`) and it is what keeps bounce
bit-identical to live.

```rust
// render side, RT-safe, Copy, no allocation
pub struct NoteEvent {
    pub frame: u64,      // absolute frame in the session timeline
    pub pitch: u8,
    pub velocity: f32,   // normalized 0.0..=1.0 for DSP (Num -> f32 happens at COMPILE time)
    pub on: bool,        // true = note-on, false = note-off
    pub voice_hint: u32, // stable per-note id so off matches on
}
```

- Compiled into a **sorted, preallocated** `Box<[NoteEvent]>` per instrument node, with a
  cursor accelerator that self-heals on seek/loop — mirror `AutoLane::value_at`
  (`render/src/automation.rs:78-124`), which already solves this exact problem.
- `Num → f32` conversion happens **once, at compile time**, never on the audio thread.
- Every note-on MUST have a matching note-off, including at loop boundaries and clip edges.
  **A stuck note is the single worst failure mode here** — an instrument that never releases.
  Emit explicit note-offs at loop wrap and at clip end; test it.

---

## 3. Instruments (E2 owns)

A `Device` on a track: `{ id, kind, params }`. `kind` ∈ `synth` | `sampler` | `drum` for E2.
Params are addressed by the **existing** `track.device.<deviceId>.<paramKey>` ParamRef, so
they automate for free.

Three instruments, in this priority order:
1. **Subtractive synth** — poly, osc(s) → filter → amp env. Params: waveform, cutoff,
   resonance, ADSR, gain. Cheapest to prove end-to-end; build it first.
2. **Sampler** — map a sound across the keyboard, pitch-shift per note. Reuses the sounds
   pipeline; this is what makes the 13,971-asset vault playable.
3. **Drum rack** — pad → one-shot, no pitch tracking.

### RT rules (absolute — from the verified render survey)
- **Fixed-size preallocated voice pool.** No allocation, no locks, no I/O on the audio thread.
  Voice stealing must be deterministic (oldest-quietest), never a heap operation.
- **All signal state advances per FRAME** (`dsp/mod.rs:1-5`, `rt.rs:19-22`). This rule is what
  makes bounce bit-identical at any block size; violating it breaks the guarantee proven at
  128/417/480/512 (`render/tests/graph.rs:593-660`).
- Reuse the existing primitives rather than inventing: `Slew` (`dsp/slew.rs`) for parameter
  ramps, the 5 ms `MICRO_FADE_FRAMES` declick (`rt.rs:53-55`) for voice start/stop.
  **The engine ramp is 5 ms, not 20 ms** — the 20 ms figure is the offline splice crossfade.
- Envelope release must actually reach zero; a truncated release is a click.

### Audio-safety (house rule, absolute)
Never open a live output/monitor stream by default. Live monitoring is attended, explicit
opt-in, double-gated — the same discipline the recording lane used.

---

## 4. Ownership — who touches what (prevents merge collisions)

| Lane | OWNS | MUST NOT TOUCH |
|---|---|---|
| **E1-engine** | `timeline-core/src/{model,cmd,apply,paramref}.rs`, `contracts/command-catalog.v2.json`, note→`RtSession` baking in `render/src/compile.rs` | `render/src/dsp/**`, any Swift |
| **E2-dsp** | `render/src/dsp/**` (NEW files), the voice pool, instrument node evaluation | `timeline-core/**`, the catalog, `compile.rs` |
| **E1-ui** | `src/swift/Sources/Studio/**` (piano roll views) | `engine/**` entirely |

E2 codes against the §2 `NoteEvent` struct as a **fixture** until E1 lands it — do not wait,
and do not define your own competing shape.

---

## 5. Verification (raw exit codes only — never a printed summary)

- `cargo test --workspace` green; wasm32 still builds for `timeline-core` + `media`.
- **v1.1 projects still replay with an unchanged blake3 chain** (`v1_1_replay_regression.rs`).
- Catalog↔MCP parity green; regenerate `docs/generated/mcp-tools.v1.json` (byte-compared);
  bump the hardcoded counts (`catalog.rs`, `tests/conformance.rs`, `agent-surface/tests/parity.rs`,
  `tests/support.rs::representative_commands()`).
- **Bounce bit-identical at 128/417/480/512 with an instrument playing** — the parity gate.
- **No stuck notes**: a test that loops a region and asserts every note-on is matched.
- Every `undoable` command returns `hint: Some(cmd)` and restores pre-state exactly (proptest).
- Swift: `rm -rf .build && MAJIKS_ENGINE=mock swift build; echo EXIT=${PIPESTATUS[0]}` = 0.
  ⚠️ `swift test` currently exits 1 for a PRE-EXISTING reason (`StudioMCPHostTests` asserts no
  live token renders, but a real `mms_` token now exists in this machine's keychain; and
  `StudioTransportTests` is wall-clock flaky). `swift build` is the gate.
- **Prove the audio, not the model.** The solo bug shipped for months because a UI-state test
  passed while nothing was audible. Assert on **rendered buffers**: a note produces signal at
  the expected frame, silence before it, and release actually decays. Mutation-check your
  tests — neuter the feature and confirm they FAIL.

---

## 6. Scope discipline

E1/E2 are **not** a full DAW instrument suite. Deliver a synth, a sampler, a drum rack, and a
piano roll that a musician can actually use. Explicitly out of scope: MPE, microtuning,
per-note expression curves, plugin hosting (E4 — deferred, breaks the provenance journal),
sidechain (E5). If a "small addition" starts pulling those in, stop and report.
