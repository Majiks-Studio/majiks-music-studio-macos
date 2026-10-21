# Session View — what it would cost, and whether to build it

**Branch:** `design/session-view` off `feat/ms-342` @ `2965425` (v3.4.7) · **Date:** 2026-07-26
**Method:** read of the tree, plus throwaway probes (marked ⚑). No GUI was launched. No product code changed.
**Model:** `DESIGN-E5-routing.md` — a seam spec written so parallel lanes cannot disagree.

> **This document is a decision, not a build order.** It answers "what would Session View
> really cost" with a number derived from reading the render loop, and it recommends **not
> building it now**. §§4–8 are a real design, written to E5's standard, because a cost estimate
> you cannot act on is a guess with a bigger vocabulary — and because the day the decision
> flips, this is the spec. If the owner says build, the lanes in §11 can start the same day.

---

## 0. What Session View is, for someone who does not use a DAW

Today the Studio is a **timeline**: a horizontal strip of time running left to right, with
audio and MIDI laid out on it like items on a calendar. You place things, you press play, the
playhead sweeps across, you hear what it passes over. Every DAW has this. It is called the
**Arrangement**, and it is how you finish a song.

Ableton Live has a second, completely different screen for the *same* project. It is a
**grid**: each column is one instrument (a track), and each column holds a stack of small
boxes. Each box holds one loop — four bars of drums, a bassline, a vocal chop. Nothing has a
position in time. You click a box and that loop starts playing, and keeps repeating until you
tell it to stop or click a different box in the same column. Click a box in another column and
now two loops play together. A horizontal row of boxes is a **scene** — click the scene and
every loop in that row starts at once.

The part that makes it musical rather than chaotic: **the click does not take effect
immediately.** You click during bar 3, and the loop waits and starts precisely on bar 4. You
are never fighting the timing. That waiting is called **launch quantization**, and it is the
entire feature. Without it you have a soundboard; with it you have an instrument.

The workflow it enables — and it is a *workflow*, not a button — is: pile up twenty ideas as
loops, jam with them until an arrangement emerges by ear, then press record and **capture the
jam onto the timeline** as a real arrangement you can edit. For a very large number of
electronic musicians that is the whole reason they use Live and not Logic.

Two facts about it that matter to this decision:

- **It is a second way to make music inside one app.** Not a feature bolted to the timeline —
  a parallel mode with its own model, its own scheduler, and its own recording path.
- **It is for arranging loops you already have.** It presumes a library of loops and a way to
  browse them. That is what makes it relevant to a 13,971-asset sounds vault, and it is also
  where the cheaper answer in §10 comes from.

---

## 1. Ground truth — verified in this tree, at this commit

Every row was read at the cited `file:line`. Rows marked ⚑ were confirmed by running something.

| # | Fact | Where | Bearing |
|---|---|---|---|
| 1 | **There is exactly one render function.** `RenderCore::render` — *"the cpal callback, the offline bounce, and the null test all run exactly this code."* | `render/src/rt.rs:1615-1617`; `render/src/offline.rs:1-8` | Any scheduler put inside it is automatically in the bounce. §7. |
| 2 | **Playback is position-based and stateless per track.** `sum_clips(track, position)` is a pure function over an immutable `Box<[RtClip]>` sorted by `start_frame`, with an early break. **There is no per-track "currently playing clip" state anywhere** — no cursor, no active set, no index. | `rt.rs:704-726`, `rt.rs:284-299`, `compile.rs:193-194` | The framing is correct. A launcher needs mutable RT state that does not exist. §4. |
| 3 | ⚑ **The musical grid ALREADY crosses to the audio thread, frame-exactly, in exact rational integer math.** `BeatClock::frame_of_beat` is `pub`, `u128`, round-half-up, and reproduces `TempoMap::tick_to_frame` term for term. It is fed from six atomics pushed unconditionally on every param sync — **not gated on the metronome being enabled**. | `render/src/dsp/click.rs:137-149`; `params.rs:192-197`; `agent-surface/src/host.rs:1453-1466` | **The single most important finding in this document.** The metronome lane, landed three commits ago on this branch (`93e39ce`), built the launch-quantization substrate by accident. §4.1. |
| 4 | **`BeatClock::resync` is already "the first beat at or after frame N"** — bounded work, no allocation, self-healing on a seek or loop fold. It is `fn`, not `pub fn`, and beat-granular. | `click.rs:164-186` | Launch quantization is ~15 new lines, not a new subsystem. §4.1. |
| 5 | **`Slew` arrives EXACTLY on target** (`delta.abs() <= step → now = target`), so a settled gain multiplies bit-exactly. `MICRO_FADE_FRAMES = 240` (5 ms @ 48 kHz). | `dsp/slew.rs:33-44`, `slew.rs:51-68`; `rt.rs:62-64` | Clip start/stop declick is a solved problem. Reuse. §4.3. |
| 6 | **`CoreConfig::monitor` is a structural export firewall.** *"There is no parameter, no command and no atomic that can turn it on for a bounce."* The metronome and count-in ride it; `ManualRenderer::new` hardcodes it false. | `rt.rs:538-551`; `offline.rs:31-48`; `rt.rs:2232` | **This is the whole answer to "what does bouncing Session View mean".** §7. |
| 7 | **A non-journaled live-trigger bus already exists.** `RenderCommand::PreviewNoteOn/Off` — *"feedback, never an edit: nothing here touches the note lane, the journal, or the transport, and the offline bounce never receives one of these."* Fixed 16-voice table, oldest-stolen, no allocation. | `rt.rs:444-492`, `rt.rs:494-527`, `rt.rs:1392-1491` | The launch trigger belongs on this bus. §6.2. |
| 8 | **24 of 113 catalog commands are `journaled: false`, by contract, with a stated rationale** — every `transport.*`, every `record.*`, every `midi.*`. *"transport commands are real commands on the bus but never appear in journal.jsonl."* All 24 route to `CmdEffect::unjournaled_noop()`; the invariant is **`journaled:false` ⟺ mutates nothing**. | `command-catalog.v2.json` (`transport.play` et al.); `apply.rs:48-56, 843, 867, 877, 884, 889` | **The provenance question has a precedent, and it is load-bearing.** §6. |
| 9 | **A whole MIDI take is 3–4 journal entries, not N.** `land_midi_capture` emits `txn.begin` → [`clip.placeMidi`] → **one batched `note.add` carrying every note as an array** → `txn.commit`. Shared verbatim by `record.stop` and by `performance.keep`. | `agent-surface/src/host.rs:2400-2504`; `cmd.rs:289-299` | **This is the exact shape "capture a jam into the arrangement" must take.** §6.3. |
| 10 | **The retro-capture buffer is a bounded, ephemeral, unjournaled performance record with an explicit human "keep".** 128 beats / 4096 notes. *"Nothing is journaled until a human asks to keep it."* Not a catalog command, by design. | `host.rs:256-268, 320-328, 1018-1047`; `registry.rs:631-634` | The second half of the provenance answer, already shipped. §6.3. |
| 11 | ⚑ **`transport.loop.set` works, engine-side, and folds SAMPLE-EXACTLY with no seam declick** — `assert_eq!(out[2_000], out[1_000])`. The fold also fires `all_notes_off` per track, because a wrap note-off cannot be baked. **But there is no loop brace in the UI**: the only Swift caller is the revise/audition flow. | `rt.rs:1732-1741`; `tests/playback.rs:169-201`; `StudioViewModel.swift:1105,1114` | Feeds the cheaper alternative. §10. |
| 12 | ~~⚑ **Warp is DEAD in the product.**~~ **FIXED on `feat/warp-alive` (2026-07-26).** It was true as written: `StudioHost` passed `&WarpOverlay::new()`, an empty overlay, at all four compile sites. It now passes `&self.warp_overlay()`, derived from `Clip::warp`, and `agent-surface/tests/warp_audible.rs` proves a 2× warp set through `submit_json` doubles the rendered duration while holding 440 Hz. **The ENGINE prerequisite is met; a GUI warp control is still absent** (no Swift caller sets `clip.warp.set`), as is `WarpMode::Conform`. | `agent-surface/src/host.rs:1300-1385` (`warp_overlay`), `1368, 2716, 2757, 2963`; `render/src/warp.rs` (`WarpCache`, `deterministic_stretcher`) | **A hard prerequisite the 4–6 week estimate omits.** §9. |
| 13 | **`TempoMap` never reaches the audio thread.** `RtSession` has no tempo, no ticks, no PPQ; everything musical is baked to frames control-side. The only musical time on the RT side is the metronome grid (row 3). | `rt.rs:399-423`; `params.rs:188-197` | The architecture's answer is "resolve control-side". Launch quantization is the first feature that legitimately cannot. §4.2. |
| 14 | **`TempoMap::bar_to_tick` hardcodes 4/4** (`bar * 4 * PPQ`), ignores `Project::time_sig` and ignores the phase anchor. `frame_to_tick` hardcodes segment 0. `MetroConfig` reads `time_sig.numerator` but the grid step is hardcoded to `PPQ` — **the denominator is ignored everywhere in Rust**. | `timeline-core/src/tempo.rs:193-209`; `click.rs:141`; `host.rs:1461-1466` | A bar-quantized launcher in 6/8 would be wrong, silently. §12.5. |
| 15 | **A session swap crossfades over 240 frames and renders TWO sessions at once**, each with its own note cursor. Swaps land at a **block** boundary, via a bounded `crossbeam_channel` drained by `try_recv` at block start. | `rt.rs:1275-1360, 1495-1583`; `engine.rs:123, 226-236` | Rules out "recompile per launch": block-granular timing is up to ~10.7 ms of jitter at 512. §4.4. |
| 16 | **The provenance manifest walks `project.tracks[].clips` and nothing else.** `for track in &project.tracks { for clip in &track.clips {` | `agent-surface/src/export.rs:210-211` | A new session-slot collection would be **silently invisible** to the AI Act disclosure. §6.5 — this is the one that would ship quietly. |
| 17 | **The journal has no compaction, no bound, and is fully rewritten on every save.** `Vec<Envelope>` unbounded, `seen_ids: HashSet<String>` unbounded, `Package::save` writes every entry from 0 and fsyncs. `FileJournal` does one `write(2)` + `flush` **per journaled command**. | `session.rs:122-137, 134`; `package.rs:53-104, 138-163` | Why per-launch journaling is not merely inelegant. §6.1. |
| 18 | **The provenance classifier is O(journal) on a 30 Hz UI path.** `clip_origins(p, session.journal())` inside `project_json()` → `snapshot()`. The diff window is 512 entries; overflow forces `Changes::Resync`, i.e. a full snapshot rebuild. | `host.rs:3034-3041, 2941-2951`; `session.rs:26, 405-407, 523-534` | A live jam that journaled per launch would degrade the UI as it ran. §6.1. |
| 19 | **Measured scale baseline:** 32 tracks / 1,536 clips / 381 s → **1,568 journal entries, 29.90 ms save, 122 MB RSS.** | `HANDOFF-perf-scale.md:20-31` | ~1 entry per clip. The arithmetic in §6.1 rests on this. |
| 20 | **No allocation on the audio thread is enforced by a real global allocator + thread-local scope depth**, with a mandatory positive control before every zero-assertion (*"THE GUARD IS BLIND"*). | `render/src/guard.rs`; `tests/null_and_alloc.rs:26-27, 338-362` | Any RT launch state must be a fixed preallocated array. §4.2. |

### 1.1 Corrections to the brief that commissioned this document

Stated plainly, because three of them change the arithmetic.

1. **"Bounce bit-identical at 128/417/480/512, pinned digest blake3 `7f2d161c…d5ae` over 240,000 frames" conflates two different gates.** They are separate:
   - The **pinned digest** is `REFERENCE_BOUNCE_1920796` at `agent-surface/tests/e5_params_seam.rs:141-171`. It runs `host.render_master()` **once**, and `render_to` hardcodes `chunk = 512` (`host.rs:2632`). It is a **single-block-size, cross-commit** pin — the only digest constant in the repo, and the strongest regression gate there is.
   - The **128/417/480/512 sweep** is a separate family (~13 tests: `graph.rs:667, 788, 1622, 2325`, `fx.rs:240`, `inert_lanes.rs:337`, `instrument_wiring.rs:224`, `metronome.rs:369`, `solo.rs:346`, `notes_bake.rs:415`, `sampler_binding.rs:554`, `instruments.rs:256-298`, `fx_param_automation_audible.rs:230`). **None of them pins a constant** — each compares 128 against the other three *within one run*.
   Both must stay green. They fail differently and they catch different bugs, and a lane told "the digest is swept at four block sizes" will look for the wrong thing.

2. **The catalog is 113 commands / 138 MCP tools, not 137.** ⚑ `mcp-tools.v1.json:6` reads `"toolCount": 138` and its `tools` array is 138 long (112 command tools = 113 − the one `gen.landed` exclusion, + 26 composite/read/session tools). The string `137` appears nowhere in code; it survives only in `ASSESSMENT-competitive-parity.md`.

3. **There are ELEVEN count sites, and the eleventh is RED right now.** ⚑ `engine/contracts/conformance_py/test_conformance.py:222` asserts `len(catalog["commands"]) == 102` against `command-catalog.v2.json`, which has 113. Running it: `1 failed, 76 passed, 1 skipped` — `assert 113 == 102`. **It has been red for eleven commands' worth of drift and nobody noticed, because `engine/run-tests.sh` never invokes the Python suite.** The E5 doc's "ten sites" list does not contain it. Also note `deferred_proposals.rs`, listed there as a count site, holds names and no numeric literal.
   > This is the repo's characteristic defect sitting inside the very machinery a new command family has to touch. Any lane that adds commands must fix it or explicitly record why not. It is also an argument for the recommendation in §3: eleven coupled count sites, one of which the gate cannot see, is friction on *every* contract change.

4. **`MidiCapture` is not a retro-capture buffer with a rolling window** — the *rolling window* is a policy the host applies to it (`PERFORMANCE_WINDOW_BEATS`, `trim_completed_before`). `MidiCapture` itself is the capture container shared by `record.stop` and `performance.keep`. The distinction matters in §6.3, where the container is the thing to copy and the window is the thing to re-derive.

5. **The E5 doc's row 18 is stale in the other direction.** `docs/evidence/l2-render-graph.md` exists (17,932 bytes) and `engine/render/README.md` does not, so its "still does not exist, cited by `render/README.md:38`" is now wrong on both halves. Recorded, not repeated.

---

## 2. Invariants — violating any of these is a defect, not a tradeoff

Inherited from E0 §1 and E5 §1, re-stated because a second execution model is the thing most
able to break them.

1. **Additive only.** No v1.1 or v2 command is renamed, removed, or has a field repurposed.
2. **Old projects replay identically**, byte for byte, including the blake3 chain.
3. **No allocation, no locks, no I/O, no logging on the audio thread.** Fixed preallocated
   pools, deterministic stealing.
4. **ALL signal state advances per FRAME.** Block boundaries only read atomics into targets.
5. **New semantics get NEW command names** (E0 §9.2). Replay does not validate params and no
   type uses `deny_unknown_fields`, so an added optional field makes an older binary verify the
   chain and build a *wrong model with no integrity signal*. `ENVELOPE_HASHED_FIELDS` is
   permanently seven.
6. **There is exactly one render function.** Anything that forks it is wrong by construction.
7. **Every journaled mutation has a truthful inverse**, proven by `undo_fidelity.rs`'s
   `assert_roundtrip` on a cloned pre-state, not by a model-state assertion.

---

## 3. The recommendation

**Do not build Session View now. Build the loop-audition package in §10 instead. Revisit when
one of the three triggers in §13 fires.**

Three sentences the owner can act on:

> **The engine can absorb Session View cleanly — the metronome lane accidentally shipped the
> frame-exact musical clock it needs, the `monitor` export firewall already answers "what does
> bouncing it mean", and the catalog's 24 non-journaled transport commands already answer
> "does a clip launch belong in the provenance chain". So this is not blocked on architecture;
> it is a priority call.** It costs **7–10 lane-weeks** rather than 4–6, because the estimate
> omitted a dead warp path that a loop launcher cannot work without (row 12), an eleven-site
> contract tax, and a Swift mock-parity tax this repo pays on every command. **And it is a
> second way to make music in an app where the first way is not finished** — a musician still
> cannot load a sample, browse a device, or quantize a note, so Session View would be the
> second front door on a house with no kitchen.

The honest counter-argument, stated so the decision is made against it and not around it:
`ASSESSMENT-competitive-parity.md:293` records an Ableton user pressing Tab forty-five seconds
in and finding nothing, and calls that *"not a missing feature; it is a missing product."*
That is true and it will not be fixed by anything in §10. **If the product's answer to "who is
this for" becomes "performers who would otherwise buy Live", the recommendation inverts.** It
is a positioning decision wearing an engineering costume, exactly like E4 plugin hosting, and
it should be made the same way — deliberately, once, by the owner.

What is *not* a reason to defer: the engine. Every hard technical question below has a clean
answer that reuses machinery already in the tree. This design would be pleasant to build.

---

## 4. The scheduler

### 4.1 DECISION — launch quantization lives on the audio thread, in a `LaunchClock` extracted from `BeatClock`

The architecture's standing answer to musical time is *resolve it control-side and hand the RT
thread frames* (row 13). **Launch quantization is the first feature that legitimately cannot
obey that rule**, and the reason is not aesthetic: a launch arrives asynchronously, is drained
at a block boundary, and must take effect at a musical boundary that may be up to a bar away.
Only the audio thread knows the frame it is on when the boundary arrives. Computing the target
frame control-side would mean computing it against a *stale* position — off by up to one block
(10.7 ms at 512), which on a downbeat is an audible flam.

**The good news is that the RT thread already has everything it needs** (row 3). The metronome
carries the model's exact rational BPM, the project phase anchor in ticks, and
`beats_per_bar` across the boundary as six atomics, pushed unconditionally by
`sync_metronome_params` whether or not the click is enabled. `BeatClock::frame_of_beat` then
redoes `TempoMap::tick_to_frame`'s round-half-up `u128` division per beat, so *the click lands
on the frame the timeline says the beat is on*. That is precisely the property a launcher needs.

```rust
// render/src/dsp/click.rs — NEW, alongside the existing `resync`, same math.
impl BeatClock {
    /// The first grid boundary at or after `position`, where a boundary is
    /// every `quantum_beats` beats measured from beat 0 (the phase anchor).
    /// `quantum_beats == 0` means "now": returns `position` unchanged.
    ///
    /// Bounded work: one divide to bracket, then at most a couple of steps —
    /// the same shape as `resync`, which this is a generalisation of.
    /// Allocation-free and `&self`, so a caller can ask without disturbing the
    /// click's own cursor.
    pub fn boundary_at_or_after(&self, position: u64, quantum_beats: u64) -> u64;
}
```

- `quantum_beats = beats_per_bar` → next bar. `= 1` → next beat. `= 4 * beats_per_bar` →
  next 4-bar phrase. `= 0` → immediate. That covers Live's whole launch-quantize menu with one
  parameter and no new math.
- **`&self`, deliberately.** The launcher must not perturb the metronome's `next_beat` cache;
  two consumers of one mutable cursor is a desync waiting to happen.
- ⚠️ **It inherits row 14's bug.** `frame_of_beat` steps by `PPQ` — one *quarter note* — and
  ignores the time-signature denominator. In 6/8 a "bar" of six beats would be six quarters,
  i.e. twice too long. **The launcher must not silently inherit this.** Either fix the grid
  step (`PPQ * 4 / denominator`) as part of this work, or refuse a non-`x/4` meter with a typed
  error naming the limitation. Do not ship a launcher that is quietly wrong in 6/8; that is the
  defect class this program keeps catching.

**Owner: SV-clock.** This is a pure function plus unit tests against `TempoMap` at several
tempos and anchors. It is the smallest and most mechanical piece of the whole epic.

### 4.2 DECISION — the RT-side data structure is a fixed `[SlotState; MAX_TRACKS]` on `RenderCore`, preallocated in `new`

Row 20 forbids allocation; row 2 says the state does not exist yet; row 15 says a session swap
must not destroy it.

```rust
// render/src/rt.rs — RenderCore, allocated ONCE in `new` from CoreConfig,
// never resized per session. `max_tracks` is 64 (engine.rs:66).
launch: Box<[SlotState]>,          // len == cfg.max_tracks
launch_clock: BeatClock,           // NOT the metronome's; its own instance
launch_log: LaunchRing,            // fixed 1024 events, §6.4

/// Per-track session-launch state. `Copy`, POD, no heap.
#[derive(Clone, Copy)]
struct SlotState {
    /// Slot queued to start, and the frame it starts on. `None` = nothing queued.
    pending: Option<(u16, u64)>,
    /// Slot currently sounding, and the frame it started on.
    playing: Option<(u16, u64)>,
    /// Frame the playing slot stops on (a queued stop). `u64::MAX` = until told.
    stop_at: u64,
    /// Fade for the outgoing slot. Rides MICRO_FADE_FRAMES like everything else.
    fade_out: Slew,
    /// Slot being faded out, still rendering. `None` once settled.
    retiring: Option<(u16, u64)>,
}
```

**Where it lives, and why that is the interesting question.** `rt.rs:314-322` already settles
this question once, for note cursors, and `strip.rs:33-40` settles it the other way for lane
cursors. The rule the file arrives at is: *snapshot-lifetime when the old session must keep
rendering its own copy through the crossfade; engine-lifetime when the state is self-healing
against a stale value.*

**DECISION: `launch` is ENGINE-lifetime, on `RenderCore`, not on the snapshot.** A launched
loop must survive an unrelated edit. The user launches a bassline, then nudges a fader on
another track — `sync_after_mutation` recompiles and swaps the whole session (`host.rs:589`, `:1295`),
and if launch state rode the snapshot the bassline would stop dead. That is unusable.

**Consequence — the stale-slot hazard, restated.** This is `clear_track_solos_from`'s twin
(`params.rs:152-160`) and E5 §6.3's twin, and it will bite: slot indices are assigned by
`compile`, so after a swap a retired index either points at nothing (harmless) or at a
*different clip* (wrong, and audible as "the loop changed by itself"). **Mitigation is
mandatory and structural:** `RtSession` carries a per-track `slot_epoch: u32` minted by
`compile` from a hash of the track's slot contents; `SlotState` carries the epoch it launched
under; a mismatch on install means **stop that track's slot with a `MICRO_FADE_FRAMES` fade and
clear the state**, rather than silently rendering the wrong loop. Stopping is the honest
failure; continuing with a recycled index is the silent one. §12 mandates a test that dirties a
retired slot, swaps, and asserts silence rather than the wrong audio.

### 4.3 DECISION — start and stop are `Slew`-gated, never abrupt, and the launch frame is exact

Reuse; do not invent. Row 5 says `Slew` arrives exactly on target, so a settled gate is
bit-exactly `1.0` and multiplies without changing the low bit.

- **Start.** At `position == launch_at`, the slot begins rendering from its own frame 0 with
  `fade_in` snapped to 0 and ramping to 1 over `MICRO_FADE_FRAMES`. The *timing* is
  sample-exact (the boundary frame came from `frame_of_beat`); only the *gain* ramps. 5 ms of
  fade-in on a downbeat is inaudible; 10 ms of timing jitter is not. That asymmetry is the
  whole reason the clock is on the audio thread.
- **Stop, and slot-to-slot swap.** The outgoing slot moves into `retiring` and keeps rendering
  under `fade_out` until the `Slew` settles, exactly as `old_session` keeps rendering through a
  swap crossfade (`rt.rs:923-935`). Cutting it dead would click on every launch, which in a
  performance context means on every bar.
- **Clip edges inside a slot** already get the implicit micro-fade from `compile.rs:196-223`
  when the material is not sample-continuous — a slot clip is an ordinary `RtClip` and inherits
  it for free.
- **Loop wrap inside a slot** must fire `all_notes_off` on that track's instrument on exactly
  the wrap frame, for the same reason `folded` exists (`rt.rs:1718-1725`): the authored note-off
  lies past the wrap and is never reached. **This is a per-track fold, not the global one**, so
  `folded` becomes `folded || slot_wrapped[idx]` at the `render_track_frame` call site and
  nowhere else.

### 4.4 What is REJECTED, and why — recompile-per-launch

The tempting cheap path: on launch, build a session whose arrangement contains the loop at the
right place, and push it. **It cannot work, and the reason is worth writing down so nobody
re-proposes it in three months.**

`SetSession` is drained by `try_recv` at the **top of a block** (`rt.rs:1621, 1495`) and
installs with a 240-frame crossfade. So the earliest a recompiled session can take effect is
the next block boundary — quantization granularity of up to `max_block_frames`, and in practice
whatever cpal hands you. At 512 that is ±10.7 ms of jitter on a downbeat, which is a flam a
drummer would be fired for. It also means every launch pays a full `compile_session_full` over
every clip, note and lane in the project (`host.rs:589` → `:1295` → `compile_session_full`), on the UI thread, during a performance.

**Report and stop if a lane finds itself proposing this.**

---

## 5. Coexistence — is Session a mode, a layer, or a transport?

### 5.1 DECISION — Session is a LAYER, per-track, overriding the arrangement. Ableton's answer fits, and it is cheap here.

Live's model: launching a session clip on track T silences T's arrangement clips until the user
presses **Back to Arrangement**, which restores every overridden track at once. Other tracks
are untouched. **This fits this engine unusually well**, because `sum_clips` is already a pure
function called once per track per frame at exactly one site (`rt.rs:912`). The override is a
branch at that site and nowhere else:

```rust
// render/src/rt.rs — inside render_track_frame, replacing the single
// `sum_clips(track, position)` call. `launch` is Copy, read by index.
let (sum, f) = match launch.playing {
    None => sum_clips(track, position),        // IDENTICAL to today, byte for byte
    Some((slot, started)) => sum_slot(track, slot, position - started),
};
```

Three properties this buys, each of which is the reason to prefer it over the alternatives:

- **The legacy path is an identity.** `launch.playing` is `None` for every track of every
  project that has no session slots, so the arithmetic below the branch is untouched and the
  `7f2d161c…` digest is provably unmoved. §7 and §12.1 rest on this.
- **The strip is unchanged.** A session clip goes through the same gain, pan, EQ, gate, insert
  chain, sends and routing graph, because it lands at the clip layer where the instrument and
  the bus injection already land (`rt.rs:904-956`). Nothing about E5 needs revisiting.
- **"Back to Arrangement" is one command that clears `playing`/`pending` on every track**, with
  each cleared track's outgoing slot riding its `fade_out`. It is genuinely trivial.

**One transport, not two.** The session layer reads the same `position` for its boundary math
and its own `started` offset for playback. Two independent transports would need two playheads,
two loop regions, two sets of note cursors and a second `folded` — and would give the user two
places to press play. Rejected.

### 5.2 The consequence that must be stated, not discovered

**A session clip can play while the transport is stopped, and this is a real decision with a
real cost.** Live does this and users expect it. Here, `render_track_frame` renders clips only
under `if playing && transport_gain > 0.0` (`rt.rs:910`), with one existing exception —
`preview_active > 0` renders the instrument alone while stopped (`rt.rs:938-949`).

**DECISION: session slots play while stopped, on the `preview_active` precedent, and the
transport keeps running underneath.** The launch clock needs a monotonically advancing frame
counter for its boundary math, so on the first launch with the transport stopped the engine
starts the transport internally *without* moving the arrangement's audible playhead — i.e.
`playing = true`, `transport_gain` ramps, but arrangement `sum_clips` stays gated on a separate
"the user pressed play" flag.

⚠️ **This is the single subtlest thing in the design and it is where a two-transport model
would sneak back in.** The honest alternative — session clips only sound while the transport
rolls — is a real option, costs nothing, and is *wrong for the workflow*: the first thing
anyone does in Session View is click a loop with the transport stopped. If a lane finds the
separated flag turning into a second position counter, **report and stop**.

---

## 6. Provenance — the sharpest question, and it has a shipped answer

The brief frames this as a dilemma: journal thousands of launches and the chain explodes; do
not journal them and the manifest can no longer claim to describe how the music was made.

**Both horns are false, and the reason is that the codebase already faced this exact question
twice and answered it the same way both times.**

### 6.1 First, the cost of the naive path, with numbers

Journaling one entry per launch is not merely inelegant. Per launch you would pay:

- a blake3 hash over canonical JSON, chained (`envelope.rs:260-269`);
- a push onto an **unbounded** `Vec<Envelope>` and an **unbounded** `HashSet<String>` of
  entry ids (`session.rs:124, 134`) — neither is ever pruned, and there is **no compaction
  mechanism anywhere** (row 17; the only mention of the word is aspirational at
  `session.rs:426`);
- **one `write(2)` + `flush` syscall**, unconditionally (`package.rs:78-91`);
- a slot in a **512-entry** diff window; overflow forces `Changes::Resync`
  (`session.rs:26, 405-407, 523-534`);
- and thereafter, on **every** subsequent save, a full rewrite of the journal from entry 0
  plus an fsync (`package.rs:138-163`).
- Worse, `clip_origins` is **O(journal)** and runs inside `snapshot()` on a **30 Hz** UI path
  (`host.rs:3034-3041`). A live jam that journals would get visibly slower as it played.

Calibration from row 19: a 32-track, 1,536-clip, 381-second real session is **1,568 entries and
a 29.90 ms save**. A ten-minute jam at four launches per bar at 120 BPM is ~4,800 launches —
**three times the entire journal of a finished 32-track song, produced by pressing buttons**,
and each one competing with the audio callback for the disk.

### 6.2 DECISION — a clip launch is NOT journaled. It is a transport command, and the catalog already has that category.

Row 8 is the finding that dissolves the dilemma. **24 of 113 commands are already
`journaled: false`**, and the catalog states the rationale in its own words:

> *"Unjournaled per 02-ARCH section 4: transport commands are real commands on the bus but
> never appear in journal.jsonl."* — `command-catalog.v2.json`, `transport.play`

`transport.play`, `transport.stop`, `transport.seek`, `transport.loop.set`,
`transport.loop.clear`, `transport.metronome`, all four `record.*`, all nine `midi.*`,
`autolane.show` and `take.auditionMix` are already outside the chain, and the invariant holds
in both directions: **`journaled:false` ⟺ mutates nothing** — every one of the 24 lands in
`CmdEffect::unjournaled_noop()` (`apply.rs:48-56`).

**A clip launch mutates nothing.** It changes what you hear, exactly like `transport.play`.
It is architecturally identical to `transport.seek` — a statement about where the engine is
listening, not about what the project *is*.

So the new commands split cleanly, and the split is not a compromise:

| Command | Journaled | Why |
|---|---|---|
| `session.slot.set` / `.clear` | **yes**, undoable | Puts a clip in a slot. Real project content. |
| `session.scene.add` / `.remove` / `.rename` | **yes**, undoable | Real project structure. |
| `session.slot.launchOpts.set` (quantum, loop, follow) | **yes**, undoable | Authored per-slot behaviour, saved with the project. |
| `session.launch` / `session.stop` | **no** | Transport-class. Mutates nothing. |
| `session.scene.launch` / `session.stopAll` | **no** | Transport-class. |
| `session.backToArrangement` | **no** | Transport-class. |
| `session.capture.start` / `.stop` | **no** | Exactly `record.start`/`record.stop`'s precedent (`cmd.rs:120-121`: *"the landed take/clip is the undoable unit"*). |

**The manifest is not weakened by this, because the manifest has never described the
performance.** It describes the *project*: per-clip lineage, the generated/imported/recorded/
authored split, engine identities, the chain head (`provenance-manifest.schema.json:2`;
`export.rs:210-247`). It contains no record of a single `transport.play` today, and nobody
considers that a hole — because what a manifest for an exported file must answer is *"where did
this audio come from"*, not *"which buttons were pressed in what order"*. §7 makes that exact
statement structurally true rather than merely argued.

### 6.3 DECISION — the capture is ONE journaled batch command, shaped like `note.add`

This is where the brief says it bites hardest, and it is where the codebase's answer is
already written and tested.

Row 9: a MIDI take of two thousand notes is **3–4 journal entries** — `txn.begin`,
`clip.placeMidi`, **one `note.add` whose params carry every note as a JSON array**,
`txn.commit`. The whole take is hashed as one payload. Row 10: `performance.keep` reads a
bounded, ephemeral, unjournaled buffer of what was played and lands it through *the same*
function. The MCP registry states the pattern outright (`registry.rs:631-634`): *"a reader of
the retro-capture buffer that then submits ordinary journaled commands … the buffer itself is
ephemeral session state, so there is nothing here for replay to rebuild."*

**Session capture is that, verbatim.**

```
session.capture.start   → unjournaled; opens a bounded LaunchLog
[ the jam happens; nothing is journaled ]
session.capture.stop    → unjournaled; reads the log, then:

  txn.begin { reason: "session.capture" }
  session.capture.land { clips: [ {trackId, sourceClipId, startTicks, lengthTicks}, … ] }
  txn.commit
```

- **Three journal entries for an entire jam**, whatever its length. `session.capture.land` is
  **batch-first**, following `note.add`'s explicit precedent (`cmd.rs:289-294`: *"one chord drag
  is ONE journal entry"*). It is a new name, per E0 §9.2 — it is emphatically **not**
  `clip.place` with an extra field.
- **Its inverse is explicit and truthful**: the placed clip ids, removed. It must pass
  `undo_fidelity.rs`'s `assert_roundtrip` against a cloned pre-state like everything else, and
  its `inverseShape` is `"multi"` — never `inverseRule: self`.
- **The manifest then describes the jam completely**, because after capture the jam *is*
  ordinary arrangement clips with ordinary per-clip lineage, classified by actor exactly as a
  recorded take is (`export.rs:388-391`, `RECORD_ACTOR`).
- **`entryCount` stays proportional to musical decisions rather than button presses**, which is
  the property that makes the chain head in the manifest mean something (`export.rs:298-306`).

### 6.4 The load-bearing detail — capture what HAPPENED, not what was ASKED FOR

⚠️ **This is the one place in this design where the repo's signature defect would recur, and it
would recur silently.**

The tempting implementation: the control thread already knows what it sent, so build the
captured arrangement from the launch commands it issued. **That would be a fabricated
recording.** The control thread does not know the frame a launch actually landed on — the
quantization happened on the audio thread, against a position the control thread never saw
(§4.1). It does not know a launch was dropped because `try_send` hit a full channel
(`engine.rs:226-236` increments `command_overruns` and returns `false`). It does not know a
track was stopped by the epoch mismatch in §4.2. Every model-level test would pass, the
captured arrangement would look plausible, and it would **not be what the musician heard**.

That is the `0.55 + 0.25 * abs(sin(t))` transport meter in a new costume: a number computed
control-side where a measurement was required.

**DECISION: the RT thread publishes what it actually did, and the capture reads only that.**

```rust
// render/src/rt.rs — fixed ring, preallocated, POD, written by the audio
// thread and drained control-side. Same discipline as the meter tap and the
// capture tap, which already send from the frame loop (rt.rs:2262-2285).
#[derive(Clone, Copy)]
pub struct LaunchEvent {
    pub frame: u64,       // the ACTUAL frame, post-quantization
    pub track: u16,
    pub slot: u16,
    pub kind: LaunchEventKind,  // Started | Stopped | DroppedStaleEpoch
}
```

- Fixed 1024 entries. **Overflow increments a counter and the capture REFUSES to land**, with
  a message naming the drop. A partial jam silently landed as a complete one is worse than a
  refusal — this repo's own doctrine (`undo_fidelity.rs:72-84`: refuse rather than lose).
- `DroppedStaleEpoch` is in the enum on purpose: the capture must be able to tell the user
  *"track 3 stopped because you edited it mid-jam"* rather than quietly omitting four bars.
- §12 mandates a test that drives the full public path — launch through `submit_json`, jam,
  capture, bounce — and asserts the bounced arrangement matches a **capture of the live
  monitor output**, not a model comparison. Anything less proves the model and nothing about
  the music.

### 6.5 The hole that would ship quietly — session slots are invisible to the manifest

Row 16: `build_manifest` iterates `project.tracks[].clips` and nothing else
(`export.rs:210-211`). A new `Track::session_slots` collection is **structurally invisible** to
it. So a project whose grid is full of AI-generated loops, none of them yet placed on the
timeline, would emit a manifest reading `generated: 0` and the statement *"This audio contains
no AI-generated material recorded in the session provenance."*

**Under EU AI Act Article 50 that is not a cosmetic gap.**

**DECISION, and it is defensible only because of §7:** the manifest's scope is **the
arrangement, because the arrangement is the only thing that bounces**. Session slots are
deliberately excluded, and the exclusion is safe *because a slot clip cannot reach an exported
file without first becoming an arrangement clip through §6.3's capture* — at which point it
carries full lineage. The monitor firewall makes the manifest complete by construction rather
than by diligence.

Three things this obliges, all mandatory:

1. **A test asserting a project with populated slots and an empty arrangement exports a
   manifest with `clipCount: 0`** — and a comment in that test saying this is deliberate, so a
   later lane does not "fix" it into a schema widening.
2. **A test asserting a captured jam's manifest attributes generated loops correctly** —
   i.e. `session.capture.land` preserves `source_id`, so `classify_clip` finds the same
   `gen.landed` record it would for a dragged clip. If capture mints fresh clips with an empty
   `source_id`, generated material becomes `authored` and the disclosure understates. **This is
   the most likely single bug in the entire epic and it is invisible without this test.**
3. **No schema change.** Do not add a `location: "session"` field; `additionalProperties:
   false` at `provenance-manifest.schema.json` makes that a breaking widening for a gap the
   workflow already closes.

---

## 7. Bounce — what "bouncing Session View" means

**It means nothing, and that is a decision, not an evasion.**

**DECISION: Session View is a monitor-only surface. Only the arrangement bounces. The launch
scheduler is gated on `CoreConfig::monitor`, exactly like the metronome.**

Row 6 is why this is structural rather than a promise someone has to keep:

> *"THE EXPORT FIREWALL. True only for a core that is driving a real output device… There is
> no parameter, no command and no atomic that can turn it on for a bounce."* — `rt.rs:538-551`

`offline::ManualRenderer::new` — the constructor behind `render_offline`, `bounce_master`,
`bounce_region`, stem export, and every deterministic test — hardcodes `monitor: false`
(`offline.rs:31-37`). The only monitoring offline constructor carries the comment *"Nothing in
the product calls it; if you find a bounce path using this constructor, that is the bug"*
(`offline.rs:39-47`).

So: `if !self.cfg.monitor { /* launch state is never consulted */ }`, and the §5.1 branch
reduces to today's `sum_clips` unconditionally on every offline path. A bounce of a project
with a full session grid renders exactly the arrangement, bit for bit, at every block size.

**Proof obligations, both mandatory:**

- **The `7f2d161c…d5ae` legacy-null gate must be green, unmoved.** Since the §5.1 branch is
  `None → sum_clips(...)` verbatim and the whole subsystem is behind `cfg.monitor`, this is
  provable rather than hopeful. If it moves, §5.1's identity was violated.
- **A new gate:** a project with populated slots, with clips *launched* immediately before the
  bounce, bounces bit-identically to the same project with an empty grid. Mutation-check it by
  deleting the `cfg.monitor` guard and confirming the test goes red. A guard nothing tests is a
  guard a later lane deletes.

**The workflow consequence, stated in the UI and not buried:** to render a session jam you must
capture it into the arrangement first. That is Ableton's workflow too, it is what §6.3 is for,
and it is what makes §6.5's manifest scope honest. It must be *said* — an export button that
silently ignores what is currently playing is the "listed-then-refused" failure the parity
assessment calls the worst moment in its five-minute test (`ASSESSMENT-competitive-parity.md:293`).

---

## 8. What already exists that helps — the inventory

Consolidated for a lane about to start. Everything here was read at the citation.

| Machinery | Where | How it is used |
|---|---|---|
| **Frame-exact musical grid on the RT thread** | `dsp/click.rs:112-227`; `params.rs:192-197`; `host.rs:1453-1466` | §4.1. **The scheduler already exists in embryo.** Exact rational, `u128`, `pub fn frame_of_beat`, `is_accent`, self-healing `resync`, `Copy`, no allocation, pushed whether or not the click is on. |
| **`Slew`** | `dsp/slew.rs:5-68` | §4.3. Arrives exactly on target; a settled gate is bit-exactly 1.0. |
| **`MICRO_FADE_FRAMES = 240`** | `rt.rs:62-64` | §4.3. The universal 5 ms declick constant. |
| **The `monitor` export firewall** | `rt.rs:538-551`; `offline.rs:31-48` | §7. The entire bounce answer. |
| **`RenderCommand` unjournaled live bus + `PreviewNoteOn` precedent** | `rt.rs:444-492, 1392-1491` | §6.2. Where launch triggers go; fixed table, oldest-stolen, allocation-free. |
| **The 24 non-journaled catalog commands** | `command-catalog.v2.json`; `apply.rs:48-56` | §6.2. The contract precedent for a real command that never touches the chain. |
| **`land_midi_capture` + `MidiCapture` + `performance.keep`** | `host.rs:2400-2504, 1018-1047`; `midi_record.rs:34-244` | §6.3. Copy this shape exactly. Batch-first, txn-wrapped, 3–4 entries per take. |
| **`txn.begin`/`txn.commit`** | `session.rs:276-307, 364-375` | §6.3. One undo step for the whole capture. Note it groups *undo*, not entries. |
| **`transport.loop.set` + the sample-exact fold + per-fold `all_notes_off`** | `rt.rs:1732-1741`; `tests/playback.rs:169-201` | §4.3 (the wrap rule) and §10 (the cheap alternative). |
| **Session-swap crossfade with two live sessions and per-snapshot cursors** | `rt.rs:1275-1360, 923-935, 314-322` | §4.2. The precedent for "old thing keeps sounding while the new one fades in", and the precedent for deciding where state lives. |
| **`clear_track_solos_from` / `clear_edge_levels_from`** | `params.rs:152-160`; E5 §6.3 | §4.2. The stale-slot hazard, twice-solved. Do not solve it a third way. |
| **Allocator guard + mandatory positive control** | `guard.rs`; `null_and_alloc.rs:26-27, 338-362` | §12. |
| **`take.auditionMix` / `record.*` as journaled:false with a landing** | `cmd.rs:120-121`; catalog | §6.2. The exact contract shape for `session.capture.*`. |
| **Swift `StudioBarGrid` / `StudioTimelineMath` snapping** | `StudioPianoRollMath.swift:172-339`; `StudioTimelineMath.swift:9-83` | §11 (SV-ui). Phase-anchored, downbeat-aware, honours the denominator — which the Rust side does not (row 14). |

**And the honest negatives**, so no lane budgets for something that is not there:

- No `bar_to_frame`, no `beat_to_frame`, no `next_bar_at_or_after` anywhere in Rust.
- No clip cursor, no interval index, no active-clip set — `sum_clips` is a linear scan.
- No scenes, no slots, no follow actions, no launch anything, in either Rust or Swift.
- No journal compaction, no bound on the journal or on `seen_ids`.
- No comp editing across takes (capture only).
- **No working warp in the product** (row 12).

---

## 9. The prerequisite the estimate omitted — warp

> **STATUS: the engine half of this section is DONE on `feat/warp-alive` (2026-07-26).** The
> diagnosis below was correct and is preserved as written. `StudioHost::warp_overlay` now
> derives the overlay from the model's `Clip::warp` and all four compile sites read it, so a
> `clip.warp.set` submitted on the bus is audible in both live playback and the offline
> bounce, with the pinned legacy digest unchanged. What this section describes that is
> **still absent**: any GUI affordance for warping, `WarpMode::Conform`, and warp markers
> (E7). Read the rest for the design rationale, not for current state.

⚑ **`clip.warp.set` is journaled, saved, undoable and inaudible in the shipping app.** The
Swift app goes through the FFI into `agent-surface::StudioHost`, which passes an **empty**
`WarpOverlay::new()` at all four of its compile sites (`host.rs:1259, 2607, 2648, 2854`). The
real overlay — with its off-thread stretch worker, its Signalsmith and WSOLA engines, and its
bit-exact identity bypass — hangs off `render::host::ProjectHost`, which is referenced only by
`render/tests/*` and `bin/engine_proof.rs`.

**Why this is a Session View prerequisite and not a separate wish.** The premise of a clip
launcher is that you stack loops from a library and they line up. A vault of 13,971 assets is a
vault of assorted tempos. Without warp, launching a 92 BPM loop into a 120 BPM project produces
something that starts on the beat and is wrong by the end of bar one. **Launch quantization
without time-stretch is a metronome for chaos.** Every other DAW's clip launcher warps by
default, and Live's does it so invisibly that users do not know it is happening.

Cost: **~1 lane-week.** The DSP, the worker, the mailbox, the ratio clamps and the identity
bypass all exist and are tested (`render/src/warp.rs`; `render/tests/warp_and_device.rs`). The
work is plumbing the overlay through `agent-surface`'s host and proving audibility end to end,
plus deciding auto-warp-on-import (which needs `media::tempo`'s beat tracker —
`media/src/tempo.rs:71-99` — and is a real design question of its own).

It is arguably owed regardless of this decision: a journaled, undoable, saved command that does
nothing is exactly the defect class the parity assessment lists at item 0.6.

---

## 10. The 80% question — and it is closer to 85%, honestly assessed

**The alternative:** a **loop brace on the ruler** plus a **browsable, tempo-synced clip
auditioner** over the sounds vault, both on the existing timeline.

### 10.1 What that package is

| # | Piece | Cost | State today |
|---|---|---|---|
| a | **Loop brace in the ruler** — drag to set, click to clear, wired to `transport.loop.set` | 2 d | Engine works and folds sample-exactly (row 11). Zero engine work. **The command is already non-journaled**, so dragging a brace does not touch the chain — the §6.2 argument, already shipped. |
| b | **A vault browser** — the 13,971 assets, searchable, with tempo/key metadata | 4 d | `StudioBrowserView.swift` shell exists; two of its four sections are read-only lists with no gestures (`ASSESSMENT-competitive-parity.md:295`). |
| c | **Tempo-synced audition** — click a loop, hear it looping in time against the project, without placing it | 3 d | **New**: a `RenderCommand::PreviewAudio` alongside `PreviewNoteOn`, reusing §4.1's `boundary_at_or_after` for in-time start and the same fixed-table, unjournaled, monitor-only discipline. This is a genuinely small slice of §4. |
| d | **Drag from browser to timeline** | 1 d | `clip.place` exists, journaled, undoable, with lineage. |
| e | **Warp** (§9) | 5 d | Prerequisite for (c) and (d) to be musically useful. |

**≈ 3 lane-weeks**, against 7–10.

### 10.2 The honest argument for it

The creative loop Session View delivers is: *find a loop → hear it in time → decide → keep it →
layer another*. Steps 1–4 are the browser and the auditioner. **Session View's unique
contribution is step 5 done live — swapping alternatives at a musical boundary without
stopping** — and that is the part that costs 7 lane-weeks.

For this product specifically, three things weight the trade further:

1. **The generator makes whole songs, not loops.** The primary creative act is not "assemble
   from parts"; it is "generate, then revise". `gen.revise` with variant audition already
   exists and already drives the transport loop (`StudioViewModel.swift:1100-1119`) — the app
   *already has* a non-linear audition loop, on the arrangement, and it is the one feature in
   this area users reach today.
2. **The vault is currently unreachable.** 13,971 assets with no way to hear one is a pure
   loss; (b)+(c) converts it into an asset at a cost of one lane-week. That is the highest
   value-per-day item anywhere in this document.
3. **The app's first way of making music is unfinished.** A musician still cannot load a
   sample, browse a device, or quantize a note (`ASSESSMENT-competitive-parity.md` §6, ~28
   lane-days of P0–P2 outstanding). Shipping a second mode over an unfinished first mode
   doubles the surface that can disappoint.

### 10.3 The honest argument against it — do not let me undersell this

**The §10 package does not answer the Tab key.** An Ableton user's evaluation ends at 0:45
(`ASSESSMENT-competitive-parity.md:293`), and no amount of browser polish changes that. If the
buyer this product is chasing is an Ableton user, the §10 package is a good six months of
runway and then the same wall.

And **Session View is genuinely the differentiated place to put the agent surface.** This
product's actual moat is that agents and humans share one journaled command bus
(`ASSESSMENT-competitive-parity.md` §4.1 — nothing in the field has this). "Ask the copilot to
build a scene from the vault, then jam with it" is a demo no competitor can run, and it needs
the grid. That is a real argument, it is a *product* argument rather than an engineering one,
and it belongs to the owner.

I lean §10. I do not think it is close on cost-effectiveness. I do think it is close on
strategy, and I would not want the strategic case to be lost inside the cost case.

---

## 11. Cost, phases, and the file-disjoint ownership table

Sizing basis, from this tree: the **metronome** lane (a comparable "new RT subsystem + contract
surface + Swift wiring") landed **2,051 insertions across 20 files** in one lane
(`93e39ce`). **E5-graph**, the largest single engine lane in the repo's history, landed
**1,919 insertions across 8 files** (`db0f58e`) and was scoped as *"large — this is the epic"*.
Treat one lane-week as ~2,000–3,000 lines at this quality bar, tests included.

### 11.1 Phases

| Phase | Deliverable | Lane-weeks | Model tier |
|---|---|---|---|
| **P0 — warp** | §9. Plumb `WarpOverlay` through `agent-surface`'s host; prove audibility end to end; keep identity-ratio bypass bit-exact. Owed regardless. | **1.0** | **Mid.** Machinery exists; the judgement is the bit-exact bypass and the auto-warp-on-import question. |
| **P1 — clock** | §4.1 `boundary_at_or_after` + the row-14 denominator fix or its typed refusal. Pure function, unit tests against `TempoMap` at several tempos, anchors and meters. | **0.3** | **Cheap.** Fully specified, mechanically verifiable, no cross-file judgement. The best small-model candidate in the epic. |
| **P2 — contract** | 11 new commands (113→124, 138→149), apply arms with truthful inverses, `representative_commands()`, `deferred_proposals.rs`, package round-trip, **all eleven count sites including the red Python one (§1.1.3)**, mcp-tools regen. | **1.5** | **Frontier.** E0 §9.2's traps are subtle and silent; a widened v1 command here corrupts every future project with no integrity signal. |
| **P3 — the scheduler** | §4.2–4.4 + §5. Per-track `SlotState`, epoch invalidation, the `render_track_frame` branch, per-track fold, the `LaunchRing`, `cfg.monitor` gating, and every audio proof in §12. **rt.rs cannot be co-owned.** | **2.5** | **Frontier.** This is the epic. It is the only lane that can move the `7f2d161c…` digest. |
| **P4 — capture** | §6.3–6.4. `LaunchRing` drain, tick conversion, `session.capture.land` batching, the txn, the refusal-on-overflow, and the full-path bounce-vs-monitor-capture test. | **1.0** | **Frontier for the design, mid for the plumbing.** §6.4 is a judgement call that a cheaper model would get plausibly and silently wrong. |
| **P5 — UI** | Grid, cells, launch/stop buttons, scene column, Tab, Back to Arrangement, quantum picker, drag-from-browser, plus `StudioMockEngine` parity, `StudioHelp` entries and `StudioCommandPalette` wiring. | **2.0** | **Mid, with a frontier review pass** on the optimistic-confirm trap (§12.5 item 1). |
| | **Total** | **8.3** | range **7–10** |

**Why this is above 4–6, in one line each:** the warp prerequisite (row 12) was not counted;
eleven coupled count sites is a real contract lane, not a checkbox; the Swift mock/real dual
means every command lands twice (the metronome toggle touched *seven* Swift files); and the
capture path (§6.4) is a subsystem, not a button.

**Where it could come in at 7:** if warp is funded separately, and if P5 ships a
single-scene-column grid first rather than full scenes.
**Where it goes to 10:** if the row-14 time-signature work is done properly rather than
refused, or if follow actions are allowed in (they are out — §13).

### 11.2 Ownership — file-disjoint, on the E5 model

**Two lanes must never own the same file.**

| Lane | OWNS (exclusively) | MUST NOT TOUCH |
|---|---|---|
| **SV-warp** (P0) | `agent-surface/src/host.rs` (warp overlay plumbing only, named line ranges in the report); `render/src/warp.rs`; `render/tests/warp_*.rs` | `rt.rs`; `compile.rs`; the catalog; any Swift |
| **SV-clock** (P1) | `render/src/dsp/click.rs`; `render/tests/metronome.rs` | `rt.rs` entirely — it lands the pure function and **no wiring** |
| **SV-model** (P2) | `timeline-core/src/{model,cmd,apply,package,paramref}.rs`; `contracts/command-catalog.v2.json`; `timeline-core/tests/**`; `contracts/conformance*/**` | `render/**`; `agent-surface/**`; any Swift |
| **SV-graph** (P3) | `render/src/{rt,compile,strip}.rs`; NEW `render/src/launch.rs`; `render/tests/**` | `render/src/params.rs`; `dsp/click.rs`; `agent-surface/**`; the catalog |
| **SV-capture** (P4) | `agent-surface/src/{host,midi_record}.rs`; NEW `agent-surface/src/session_capture.rs`; `agent-surface/tests/**` | `render/src/**`; `timeline-core/**`; the catalog |
| **SV-ui** (P5) | `src/swift/Sources/Studio/**` | `engine/**` entirely |

⚠️ **SV-warp and SV-capture both name `agent-surface/src/host.rs`.** That is a real conflict
and it is resolved by **sequencing, not by co-ownership**: SV-warp merges first and touches
only the four `WarpOverlay::new()` call sites; SV-capture starts after. If they must overlap,
SV-warp's edit is small enough to hand to SV-capture as a fixture patch. **Do not run them
concurrently.**

### 11.3 Cross-lane seams — code against these as fixtures, do not wait

- **`BeatClock::boundary_at_or_after(&self, position: u64, quantum_beats: u64) -> u64`** is
  law. SV-graph codes against it before SV-clock merges. Neither lane may change it
  unilaterally.
- **`LaunchEvent` / `LaunchEventKind`** (§6.4) is law. SV-graph writes it; SV-capture reads it.
  It is `Copy`, POD, and carries the **actual** frame. SV-capture must never reconstruct a
  frame it did not receive.
- **The command names and their journaled/undoable/inverseShape triples** (§6.2 table) are law
  from SV-model. SV-ui and SV-capture code against them.
- **`RtSession::slot_epoch`** (§4.2) is minted by `compile` (SV-graph) and consumed by
  `RenderCore` (SV-graph). It does not cross a lane boundary; it is listed so nobody adds a
  second epoch scheme in `agent-surface`.

### 11.4 Merge order

`SV-warp` → `SV-clock` → `SV-model` → `SV-graph` → `SV-capture` → `SV-ui`.

SV-graph is the only lane that can take the legacy-null digest red, so it merges late enough
that a bisect over it is meaningful. SV-clock and SV-model are file-disjoint and may run
concurrently; they are ordered here only for the merge queue.

---

## 12. Verification — raw exit codes only

`cd engine && ./run-tests.sh; echo EXIT=$?` is **the** gate. Never pipe it through `tee`.
A `--filter` matching nothing returns EXIT=0 with 0 tests run; read the `running N tests` line.
Swift: `cd src/swift && rm -rf .build && MAJIKS_ENGINE=mock swift build; echo EXIT=$?` —
`rm -rf .build` is mandatory, Swift's incremental build has produced false greens here.

⚠️ **`run-tests.sh` does NOT run the Python conformance suite, and that suite is red today**
(§1.1.3). SV-model must run `python3 -m pytest engine/contracts/conformance_py -q` explicitly,
fix the 102→124 drift, and **add the invocation to `run-tests.sh`** so the eleventh count site
cannot rot the same way.

### 12.1 The gates that must not move

1. **`7f2d161c…d5ae` over 240,000 frames** (`e5_params_seam.rs:141-171`). Do not adjust it, do
   not add a tolerance. It moving means §5.1's identity branch was violated.
2. **The 128/417/480/512 sweep**, all ~13 tests, green.
3. **`null_and_alloc.rs`** — zero allocator hits in a render scope, **after** the positive
   control. A test binary without `#[global_allocator]` is vacuously green.
4. **`v1_1_replay_regression.rs`** — unchanged blake3 chain.
5. **Counts** at 124 / 149 across all eleven sites, and `mcp-tools.v1.json` regenerated.

### 12.2 Audio proofs — assert on RENDERED BUFFERS, never on model state

> Solo shipped broken for months because a UI-state test passed while nothing was audible.
> Send-level automation was inert for an entire epic. Every assertion below compares samples.

Follow `render/tests/solo.rs`: constant-DC clips at distinguishable levels (0.25 / 0.50).

1. **A launch at quantum = 1 bar starts on exactly the bar frame** `TempoMap::tick_to_frame`
   reports — frame `f-1` silent, frame `f` non-silent. Test at 92, 120 and 141 BPM and at a
   non-zero phase anchor. This is the `metronome.rs:100-121` pattern.
2. **A launch during bar 3 does not sound until bar 4.**
3. **Quantum = 0 launches on the next frame.**
4. **A slot loops**: bit-exact repetition across the wrap, on the `playback.rs:197-200` pattern.
5. **A MIDI slot's wrap releases notes** — no stuck note across the fold.
6. **Slot-to-slot swap declicks over `MICRO_FADE_FRAMES`**: assert the *ramp*, not the
   endpoints.
7. **Session overrides only the launched track**: a two-track project, one launched, asserts
   the other's arrangement is bit-identical to the un-launched render.
8. **Back to Arrangement restores every overridden track**, with a ramp.
9. **A launched slot plays with the transport stopped** (§5.2), and the arrangement does not.
10. **Stale-slot epoch**: launch, edit the track's slots, swap — assert **silence on that
    track**, not the wrong loop, and a `DroppedStaleEpoch` in the ring.
11. **THE BOUNCE GATE**: a project with populated slots, clips launched, bounces bit-identically
    to the same project with an empty grid, at all four block sizes.
12. **THE CAPTURE GATE**: launch a jam through `Session::submit_json`, capture it, bounce the
    result, and assert it matches a **monitor capture of the live render** — not a model
    comparison. This is the only test that can catch §6.4.
13. **Manifest scope** (§6.5): populated slots + empty arrangement → `clipCount: 0`, and the
    test comment says this is deliberate.
14. **Manifest lineage after capture** (§6.5 item 2): a captured generated loop classifies as
    `generated`, not `authored`.

### 12.3 Mutation checks — MANDATORY, one per proof above

Neuter the feature; confirm the test **fails**. Force `quantum_beats` to 0; force
`launch.playing` to `None`; skip the epoch check; delete the `cfg.monitor` guard; build the
capture from sent commands instead of the ring. A test that stays green when you break the
feature is not a test.

### 12.4 Test-seam honesty — name the hops

Every new test states in its doc comment which production hops it traverses.

| Seam | Traverses | SKIPS |
|---|---|---|
| `ManualRenderer` + `render_offline_with` | `RenderCommand` channel → `drain_commands` → `install_session` → the one `RenderCore::render` | cpal callback; real-time deadline |
| `EngineParams` setters called directly | the atomic store and the block-boundary load | `host.rs::sync_params` — **so it does NOT prove the host pushes anything.** This is how the solo bug survived. |
| `compile_session_full` called directly | model → snapshot | `sync_after_mutation` → `push_live_session` |

**At least two tests must drive the full host path** — proof 12 above, and one asserting that a
`session.launch` submitted through `submit_json` actually reaches the audio thread.

### 12.5 Where "looks wired and is not" would recur in THIS design

Named, because the brief asked and because each of these has a shipped ancestor in this repo.

1. **The launch button that lights up and does nothing.** The UI marks a cell "queued" on
   click, the RT never launches (full command channel — `engine.rs:226-236` returns `false` and
   only bumps a counter; wrong quantum; stale epoch), and the grid shows a playing clip that is
   silent. **Ancestor:** the ⌘K palette listing 71 commands and wiring 11. **Mitigation:** the
   cell shows *queued* on send and *playing* only on a `LaunchEvent::Started` read back from
   the ring. Confirm on success, never on submit.
2. **The capture that records intentions.** §6.4 in full. **Ancestor:** the transport meter
   that is `0.55 + 0.25 * abs(sin(t))`.
3. **Session slots silently absent from the AI Act manifest.** §6.5. **Ancestor:** send-level
   automation compiling into a lane slot that nothing read, for a whole epic.
4. **A launcher that is quietly wrong in 6/8.** Row 14 — `frame_of_beat` steps by `PPQ` and
   ignores the denominator, while the *Swift* grid honours it
   (`StudioPianoRollMath.swift:172-339`). Two grids that disagree, one of them the one you
   hear. **Ancestor:** two tempo maps, one `f64` in Swift with tempo changes, one integer in
   Rust without.
5. **A `cfg.monitor` guard nobody tests**, deleted by a later lane as dead code. Proof 11 plus
   its mutation check is the only thing that stops this.
6. **A second epoch/invalidation scheme** appearing in `agent-surface` because the RT one was
   not visible from there. Two implementations of "is this slot still valid" that disagree is a
   mix that changes depending on which path ran — the same failure `has_implicit_master_feed`
   was written to prevent.

---

## 13. Out of scope, and the triggers that change the answer

### 13.1 Explicitly out of scope for any Session View epic

Report and stop if one of these starts pulling itself in.

- **Follow actions** (a clip that automatically launches another after N bars). It is a second
  scheduler layered on the first, with its own randomness and its own determinism problem.
- **Clip envelopes** (per-clip automation loops, distinct from the timeline's). Needs a second
  automation domain; `AutoLane` is frame-absolute.
- **Session-view recording of MIDI into slots.** The capture path in §6.3 is
  session→arrangement, one direction.
- **A tempo/time-signature map.** Row 14 says the current one is *wrong*, not merely absent, on
  multiple segments. Fixing it is a 2–3 week epic of its own and Session View must not absorb
  it — it must **refuse** meters and tempo maps it cannot honour, loudly.
- **Warp markers (E7).** §9's prerequisite is *warp working at a ratio*, not free markers.

### 13.2 The triggers that should flip the recommendation to "build"

1. **A positioning decision that this product competes for Ableton users.** The parity
   assessment's five-minute test is the evidence, and it will not improve. If the answer to
   "who is this for" becomes "performers", build it, and budget 10 lane-weeks with warp.
2. **E4 plugin hosting decided as option C ("no plugins, ever").** If the product deliberately
   forgoes the largest parity item to protect the provenance chain, Session View becomes the
   biggest remaining parity item that is *fully compatible* with that chain — §6 shows it costs
   the manifest nothing — and its strategic value rises sharply.
3. **Evidence that users layer loops rather than generate songs.** If the vault browser from
   §10 ships and telemetry or feedback shows people auditioning and stacking rather than
   generating and revising, the workflow Session View serves is the workflow the product
   actually has, and §10 will have paid for the discovery at a fifth of the price.

### 13.3 What should happen instead, in order

1. **P0 of the parity assessment** — stop the app making claims it does not honour (~3 days).
2. **Warp** (§9) — a journaled, undoable, saved, inaudible command is the same defect class
   (~1 week).
3. **The §10 package** — loop brace, vault browser, tempo-synced audition, drag-to-timeline
   (~2 weeks on top of warp).
4. **Then re-ask this question**, with a working browser, working warp, and a user who can
   finish a track.

---

## 14. Unverified — confirm before relying on these

Marked because this repo's documents have been stale, and because a design doc that does not
separate what it read from what it inferred is how the next stale document gets written.

- **The 8.3 lane-week figure is an estimate, not a measurement.** It is calibrated against two
  landed lanes (`93e39ce`, `db0f58e`) and the repo's observed velocity. Treat the ordering and
  the *relative* sizes as the recommendation; treat the absolute number as ±30%.
- **`boundary_at_or_after` is specified, not written.** Its cost claim ("~15 lines") rests on
  it being a generalisation of `resync` (`click.rs:164-186`), which I read. Nobody has compiled
  it.
- **The `slot_epoch` invalidation scheme (§4.2) is designed, not prototyped.** The hazard it
  addresses is real and twice-precedented; the specific remedy has not been built.
- **"5 ms of fade-in on a downbeat is inaudible"** is a judgement from DJ/DAW practice, not a
  measurement in this engine. If it turns out to matter, the fix is a shorter launch-specific
  ramp, not a step.
- **The claim that a jam produces ~4,800 launches** (§6.1) is arithmetic over an assumed
  playing style, not observation.
- **`media::tempo`'s beat tracker has not been evaluated for auto-warp-on-import** (§9). It
  exists and emits `TempoMapEstimate` with confidence; whether it is good enough to warp a
  vault unattended is unknown.
- **I did not run `./run-tests.sh`.** The Python conformance failure in §1.1.3 was reproduced
  directly (`1 failed, 76 passed, 1 skipped`); everything else in §1 is read, not executed.
  ⚑ marks in §1 denote a probe I ran, not a full-suite run.
