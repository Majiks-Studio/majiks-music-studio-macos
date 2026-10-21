# Lane L12: Mixer + automation UI — evidence

Date: 2026-07-12. Branch `lane/l12-mixer-automation` off main `a7687a5`.
Silent throughout: the offline bounce path never opens a device, and the
preview engine (`StudioMockEngine`) produces no audio.

## What this lane wired

The engine already had the DSP: per-track strips (gain / pan / 4-band EQ /
2 sends), fixed reverb+delay buses, master with true-peak limiter + ebur128
LUFS, and sample-accurate automation rendering, all journaled + undoable
through the catalog command bus. L12 is the UI + the command-bus wiring on top:

- **Mixer dock** (`StudioMixerDock` + `StudioMixerControls`): per-track strip
  with a dB-calibrated fader, pan knob, two send knobs (A reverb / B delay),
  a live 4-band EQ response curve with draggable band nodes (the curve is the
  engine's own RBJ biquad magnitude, so it shows exactly what renders),
  mute/solo, and a peak+RMS meter. Master strip: fader, true-peak limiter
  (enable / ceiling / release), integrated + short-term LUFS, stereo
  correlation, gain reduction, and a peak + true-peak meter.
- **Automation lanes** (`StudioAutomationLane` + timeline canvas): per-track
  volume and pan breakpoint lanes under a track. Click draws a point, drag
  moves it, option-click removes it, the lane header clears it. Each edit is an
  `autopoint.*` / `autolane.*` command.
- **Command wiring**: a typed `StudioEngineCommand` case per control mapped to
  the catalog names (`mix.gain/pan/eq/send`, `mix.master.gain`,
  `mix.limiter.set`, `autopoint.add/move/remove`, `autolane.show/clear`), on
  both the mock and the FFI-backed `RealStudioEngine`, plus `undo`/`redo` on
  the engine protocol.
- **Additive engine exports** (meters only, no signal-path DSP): the
  agent-surface `meters()` now also reports short-term LUFS and limiter gain
  reduction (both were already computed by L2's meter thread, just unexposed),
  and a new block-local **stereo-correlation meter** in the master metering
  path (`rt.rs` + `stats.rs`) — a sibling of the existing block-RMS meter that
  reads the already-computed master frame and alters no sample.

## Acceptance

### Every mixer control round-trips through the bus; undo works

`engine/agent-surface/tests/mixer_automation.rs` drives the real `StudioHost`
(the instance the FFI/MCP/CLI share):

- `every_mixer_control_round_trips_and_undoes`: `mix.gain`, `mix.pan`,
  `mix.eq`, `mix.send`, `mix.master.gain`, `mix.limiter.set` each journal
  (seq advances) and land in the snapshot; undoing the stack returns every
  control to its default.
- `mixer_undo_restores_the_prior_value_not_just_default`: two gain moves then
  one undo restores the FIRST move's value (self-inverse, exact), and redo
  re-applies.
- `an_agent_fader_move_shows_up_in_the_snapshot`: an **agent-actor**
  `mix.gain` (the MCP path) lands in the same serialized snapshot the dock
  polls — the dock reflects a fader an agent moved.

Swift side (`src/swift/Tests/StudioMixerAutomationTests.swift`, mock engine):
`mix.gain/pan/eq/send`, master gain, limiter, mute, solo each round-trip into
the snapshot; undo restores eq/send/pan/master/limiter to their prior values;
`autopoint.add/move/remove` and `autolane.clear` round-trip, and undo of a
clear restores every point.

The dock reads engine truth without fighting drags: each control shows its own
value only while under gesture and holds the value it sent until the next
snapshot confirms it (the DJ edit-guard), so the 30 Hz poll never yanks a live
drag. Automation-point drags use the timeline canvas's existing drag guard.

### Automation draw → engine render → bounce is identical

`automation_draw_bounce_is_deterministic_and_applied`:

- Drawing the same volume ride (unity → -18 dB) into two independent sessions
  bounces **bit-identically** (the render is a pure function of the journal).
- The automation is really applied: the second-half tail RMS drops from
  **0.21858** (plain) to **0.03080** (with the ride) — the ~18 dB the ride
  asks for.
- Undoing every point returns the **exact** original bounce, byte-for-byte.

### No zipper noise

`automation_step_bounces_without_zipper`: a hard step (unity → -48 dB one tick
later) on a steady 440 Hz tone bounces with a max per-sample delta of
**0.02304** — identical to the steady tone's own slope (**0.02304**). The
declick slew absorbed the step completely; a raw, un-declicked step would jump
~0.4–0.5 in one sample. The engine's ramps handle it; L12 only verifies it.

## Screenshots

Rendered off-screen through `ImageRenderer` (deterministic, no window), driven
by the same view model + mock engine the app runs; the automation lane uses the
SAME shared renderer the live canvas draws with. The evidence test first drives
real commands (Vocals EQ +5 dB @ 320 Hz bell and -3 dB @ 9 kHz shelf, Backing
Vox pan L40, Drums reverb send 45%, limiter on), so the dock shown is the
round-trip result read back from the snapshot.

- `l12-mixer-automation.png` — the VO volume-automation lane (its 5-point ride)
  over the full mixer: 8 stem strips + master.
- `l12-mixer-dock.png` — the mixer close-up. Note the Vocals EQ curve reflecting
  the driven bands, the turned Backing Vox pan / Drums send knobs, and the
  master's LUFS (integrated + short-term), correlation, and enabled limiter.

Meter note (honesty): the preview engine is silent, so its meter levels are
DERIVED from the mixer state (a fader visibly moves its meter) — labeled preview
data, not measured audio. The real engine reports measured dBFS/LUFS/correlation
from its live meter path; `RealStudioEngine` merges `meters()` into the snapshot.

## Files owned

Engine (Rust):
- `engine/render/src/rt.rs`, `engine/render/src/stats.rs` — additive master
  stereo-correlation meter (+ its plumbing).
- `engine/agent-surface/src/host.rs` — `meters()` now reports `lufsShortTerm`,
  `gainReductionDb`, `correlation`.
- `engine/agent-surface/tests/mixer_automation.rs` — new acceptance tests.

Swift:
- `src/swift/Sources/Studio/StudioMixerDock.swift` — the dock + strips + master.
- `src/swift/Sources/Studio/StudioMixerControls.swift` — fader, knob, EQ curve,
  meter (new).
- `src/swift/Sources/Studio/StudioAutomationLane.swift` — shared lane renderer +
  preview (new).
- `src/swift/Sources/Studio/StudioMixerEvidence.swift` — evidence renderer (new).
- `src/swift/Sources/Studio/StudioEngineModel.swift` — snapshot types + command
  cases + protocol `undo/redo`.
- `src/swift/Sources/Studio/StudioMockEngine.swift` — command handlers,
  inverse-based undo/redo, seeded automation, preview meters.
- `src/swift/Sources/Studio/StudioTimelineView.swift` — automation-lane drawing
  (delegates to the shared renderer) + point hit-test / draw / drag / remove.
- `src/swift/Sources/Studio/StudioTimelineMath.swift` — per-target automation
  rows + `StudioAutomationMath` (value/pixel math).
- `src/swift/Sources/Studio/StudioTrackHeaderColumn.swift` — per-lane header +
  the track's automation-lane toggle.
- `src/swift/Sources/Engine/RealStudioEngine.swift` — route the new commands +
  parse eq/sends/automation/limiter + merge meters + `undo/redo`.
- `src/swift/Sources/Theme/StudioTokens.swift` — `automationLaneHeight` token.
- `src/swift/Tests/StudioMixerAutomationTests.swift`,
  `StudioMixerEvidenceTests.swift` — new.

Shared mount points (kept minimal, for reconciliation with L9 Revise):
- `src/swift/Sources/Studio/StudioViewModel.swift` — added mixer/automation send
  methods, `undo`/`redo`, `visibleAutomationLanes`, and automation-point fields
  on `StudioDragState` (new `.automationPoint` drag kind). No existing behavior
  changed.
- `engine/agent-surface/src/ffi.rs` — none (the FFI `meters()` was already
  exported; only its JSON grew, additively).
- `StudioRootView.swift` / `ffi.rs` command surface — untouched.
- `src/swift/Tests/StudioShellMathTests.swift` — one L5 row-layout assertion
  updated for the per-target automation row kind (`.automation(trackID:target:)`)
  and the "lane shows when it has points" rule.

## Green

- `cargo test --workspace`: PASS (correlation meter regressed nothing; the
  null/alloc/graph tests hold — meters touch no output sample).
- mock `swift build` + `swift test`: PASS (187 tests; 188 with the evidence
  generator enabled).
- real-engine `MAJIKS_ENGINE=real swift build`: PASS (RealStudioEngine wiring
  compiles against the built xcframework).

## Reproduce

```bash
# Rust acceptance (round-trip, undo, bounce-identity, no-zipper)
cd engine && cargo test -p agent-surface --test mixer_automation -- --nocapture

# Swift (mock) build + tests
cd src/swift && MAJIKS_ENGINE=mock swift build && MAJIKS_ENGINE=mock swift test

# Regenerate the screenshots
cd src/swift && L12_EVIDENCE=/abs/out/dir MAJIKS_ENGINE=mock swift test
```

## Notes / questions

1. **Contract vs design on EQ band count.** `COMMAND-REFERENCE.md` / the engine
   ship a 4-band channel EQ (`mix.eq` band 0-3: low shelf, bell, bell, high
   shelf); 01-DESIGN §3.7 says "3-band". I built to the contract (4 bands) and
   the mini-curve shows all four. Flagging the doc/contract mismatch; no code
   change proposed.
2. **Fader commits on gesture end**, so a fader move is ONE journaled command /
   one clean undo step. Continuous live-audio-during-drag (a `txn`-grouped burst
   of `mix.*` so you HEAR the fader move yet still undo it as one unit) is a
   v1.1 refinement; the txn brackets already exist in the catalog.
3. **Preview meters** are derived from mixer state, not measured (the mock is
   silent by rule); the real engine's meters are measured. Called out in the UI
   copy and here so it never reads as fabricated audio.
4. **Correlation meter is an additive engine change** (`rt.rs`/`stats.rs`). It
   is meter code (a sibling of the block-RMS meter, RT-safe, alters no sample),
   not signal-path DSP, added so the master strip's correlation is honest rather
   than a placeholder. Easy to revert if L2's owner prefers to own it.
