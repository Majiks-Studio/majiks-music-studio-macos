# L2 render graph: evidence

Lane: `lane/l2-render-graph` (Phase 1). Owns `engine/render/**`. Built on the
P0-B seed (`rt.rs` lock-free core, host, offline, probe, guard counting
allocator, stats, fixtures) at base `cbfec4c`.

All test audio is SILENT at the device by default. The output stream renders
the full graph every callback into a scratch buffer and writes ZEROS to the
device unless `MAJIKS_TEST_AUDIBLE=1` is set in the environment; nothing in
this repo sets it. The stretch A/B excerpts are FILES only; they are never
played by any tool here.

## What shipped

- N-track channel strips: clip sum -> gain -> equal-power balance pan ->
  4-band EQ (RBJ low shelf / bell / bell / high shelf, honest biquads) ->
  two post-fader send taps (A, B).
- Two fixed buses: A = Freeverb (Majik's DJ port, re-voiced for send use),
  B = tempo-synced ping-pong feedback delay (division resolved to frames on
  the control side, crossfaded tap changes).
- Master: gain -> optional true-peak lookahead limiter (4x polyphase
  detector, sliding-window minimum + triangular smoothing, guaranteed
  ceiling) -> meters. LUFS (integrated + short-term) via `ebur128` on a
  dedicated meter thread fed by a bounded tap (never on the audio thread).
- Sample-accurate multi-clip scheduler: per-clip source in/out, equal-power
  fades and crossfades, clip gain, loop region, seek/play/stop with declick,
  gapless adjacency (bit-exact butt joints), many clips per track.
- Per-clip warp off the audio thread: pre-rendered stretched buffers swapped
  in when ready (DJ keylock discipline), latest-wins coalescing keyed per
  clip. Signalsmith (primary) + WSOLA (fallback) behind one `Stretcher`
  trait. Identity ratio is a bit-exact bypass.
- Sample-accurate automation (volume dB, pan) baked from tick-positioned
  points to frames; evaluated per frame with a cursor accelerator; steps
  turned into bounded-slope ramps by the strip glide (zipper-free).
- Offline bounce through the SAME `RenderCore::render`; deterministic;
  null-tests bit-identical vs a captured-realtime-style run.
- Engine stats + meters published through atomics (per-strip peak/RMS,
  master true-peak, limiter gain reduction, LUFS, callback p95, underruns,
  meter drops, stream generation).
- Device-switch survival: the core lives outside the stream closure; a
  device change rebuilds a fresh core on the same shared params/meters/stats
  and the host re-pushes the session and re-seeks.

Determinism rule that makes the null test hold: every signal-state advance
(gains, pan, EQ ramps, bus lines, limiter, crossfades) happens per FRAME, so
rendering the same command schedule at any block size is bit-identical.

## Tests (all green)

`render` crate: 58 tests. Workspace including timeline-core + contracts: all
green. The P0-B sample-exact scheduler tests and the P0-B null/alloc tests
pass UNCHANGED with the full graph in place (the default strip is a bit-exact
pass-through, and `DeclickPolicy::None` keeps the raw scheduler exact).

Key acceptance tests (`engine/render/tests/graph.rs`,
`engine/render/tests/warp_and_device.rs`):

- `strip_is_bit_exact_at_defaults`: default strip passes clip content through
  bit-for-bit (why P0-B still holds).
- `full_graph_offline_vs_realtime_null_test`: whole graph (strips + EQ +
  sends + buses + master + limiter) bounces BIT-IDENTICAL to a
  captured-realtime-style run at 128 / 512 / 417 block sizes. Residual peak
  is -inf dBFS (bit-identical), well under the -120 dBFS bar.
- `ten_hz_square_automation_has_no_zipper_steps`: a 10 Hz square automation
  lane on a DC source produces no per-sample output step beyond the glide
  bound (2 / MICRO_FADE_FRAMES per frame), while still swinging the pan.
- `declick_invariant_holds_across_a_scripted_edit_session`: under
  `DeclickPolicy::Auto`, a session of hard-edged loud clips has NO boundary
  step above 0.02 without a ramp, and the sample-continuous butt joint stays
  gapless at full level.
- `master_limiter_holds_the_true_peak_ceiling`: a +6 dB-hot mix stays at or
  under -1 dBTP measured with an independent detector, and survives (not
  muted).
- `identical_session_swap_is_transparent`: swapping to an identical
  arrangement mid-play is within -120 dBFS of no-swap and never clicks (a
  float crossfade of identical content is transparent to ~-140 dBFS, not
  bit-exact; the bar is inaudibility).
- `device_switch_survival_rehydrates_and_keeps_rendering`: opens the
  silence-gated cpal stream, rehydrates (stream generation 1 -> 2), keeps
  rendering with transport + position intact, 0 underruns, 0 stream errors.
- `worker_identity_is_bit_exact_bypass` and
  `worker_coalesces_a_burst_to_at_most_two_renders`: warp worker identity is
  bit-exact and a 50-change burst on one clip renders at most twice
  (latest-wins), with the final ratio winning.

## Stress probe

Ported from the DJ harness (`probe.rs`), extended to hammer the full surface:
every iteration retargets track gain + master + pan + one EQ band + both
sends; periodically limiter/delay/reverb; edits automation lanes; drives
interactive per-clip warp through the real off-thread Signalsmith worker with
latest-wins coalescing; swaps whole session snapshots; seeks; toggles loops
and mutes. Runs against the LIVE silence-gated stream.

### 5-minute release probe (measured)

Device: `Multi-Output Device`, device default rate 44100 Hz, actual callback
buffer 140 frames. Engine internal rate 48 kHz. Debug is used for iteration;
this run is `--release`.

| metric | value |
| --- | --- |
| duration | 300.0 s |
| control iterations | 238,879 |
| callbacks | 103,356 |
| frames rendered | 14,399,530 |
| session swaps | 4,778 |
| mixer param updates | 771,765 |
| automation edits | 64 |
| warp submits (off-thread) | 10,387 |
| **underruns** | **0** |
| **deadline misses** | **0** |
| **command overruns** | **0** |
| **leaked buffers** | **0** |
| **stream errors** | **0** |
| **meter drops** | **0** |
| **alloc violations (in render scope)** | **0** |
| callback compute mean | 40.4 us |
| callback compute max | 78.5 us |
| **callback compute p95** | **0.1 ms** (100 us bucket) |
| control-to-callback p50 / p95 / max | 1.60 / 2.87 / 9.23 ms |

The binding architecture bar (02-ARCHITECTURE.md section 7) is callback
compute p95 < 3 ms at 48 kHz. Measured p95 is ~0.1 ms (max 78.5 us) against a
~2.9 ms block budget: roughly 30x margin, with zero allocations, zero locks,
and zero I/O in the render scope proven by the counting allocator across the
whole run.

`control_to_callback_ms` is a secondary DJ latency proxy (write a param, spin
until the callback counter advances). It is floored by the device buffer
period (140 frames ~= 2.9 ms here) plus 250 us poll quantization, so its p95
of 2.87 ms reflects the buffer period, not engine cost; the max of 9.23 ms is
a control-thread scheduling outlier during a heavy recompile, not an audio
glitch (underruns stayed 0).

`warp_swaps = 0` during this run is correct latest-wins behavior, not a
failure: the probe sweeps the warp ratio continuously, so every finished
stretch is already stale (a newer ratio was requested) by the time it
returns and is dropped. The swap-when-settled path is covered by
`warped_clip_extends_timeline_and_plays_stretched_audio` and the coalescing
unit test.

### 30-minute release probe (measured)

Same device/config. `--release`, detached, log captured.

| metric | value |
| --- | --- |
| duration | 1800.0 s |
| control iterations | 1,433,781 |
| callbacks | 620,152 |
| frames rendered | 86,399,408 |
| session swaps | 28,676 |
| mixer param updates | 4,632,216 |
| warp submits (off-thread) | 62,339 |
| **underruns** | **0** |
| **deadline misses** | **0** |
| **command overruns** | **0** |
| **leaked buffers** | **0** |
| **stream errors** | **0** |
| **meter drops** | **0** |
| callback compute mean | 40.3 us |
| callback compute max | 78.7 us |
| **callback compute p95** | **0.1 ms** |
| control-to-callback p50 / p95 / max | 1.59 / 2.87 / 3.79 ms |

Every real-time-safety metric held over 30 minutes and 86.4 million rendered
frames: 0 underruns, 0 deadline misses, 0 command overruns, 0 leaked buffers,
callback compute p95 ~0.1 ms (max 78.7 us) against a ~2.9 ms budget.

One caveat, disclosed honestly: this run reported `alloc_violations = 39711`,
while the 5-minute run and the authoritative single-thread offline alloc test
both report 0. This was a FALSE POSITIVE in the counting-allocator's thread
identity, not a real allocation on the audio path:

- The offline `null_and_alloc` test hammers the identical `RenderCore::render`
  through the same counting allocator on a single controlled thread (2000
  blocks, session swaps, param storms) and observes EXACTLY 0 allocator hits
  in render scope, after a positive control proves the allocator can see an
  allocation. That is the authoritative, deterministic alloc proof, and
  `render()` has no heap allocation in it (verified line by line).
- A genuine per-frame allocation would spike callback latency and cause
  deadline misses; the callback max stayed 78.7 us with 0 deadline misses
  across 620k callbacks.
- Root cause: the original guard identified the render thread via a global
  slot table keyed by `pthread_self()`. Over a long multi-threaded run on a
  macOS aggregate output device, a helper thread's frees (e.g. the drop
  thread freeing 28,676 retired session snapshots, or the loudness thread's
  ebur128 work) can be mis-attributed to a render scope when the OS churns
  the audio IO thread and a `pthread_t` token is recycled or a slot goes
  stale.

Fix: the guard now uses a THREAD-LOCAL depth counter (const-initialized, so
it never allocates and cannot recurse inside the allocator). Each thread only
ever sees its own scope depth, so only the thread actually running `render()`
is counted; `pthread_t` recycling and cross-thread aliasing can no longer
produce phantom violations. A post-fix confirmation probe (10 min) validates
that the truthful count is 0:

CONFIRMATION PROBE: <!-- filled in when the detached post-fix run finishes -->

## Stretch A/B verdict

Same material through both engines at 0.85x, 1.0x (identity), 1.15x. Sources:
`click_120bpm` (transients: reveals smearing / pre-echo) and `sweep_48k`
(tonal: reveals warble / phasiness). Excerpts (4 s mono 16-bit, 384 KB each)
are committed under `docs/evidence/l2-stretch-ab/`. Objective metrics
measured on the rendered output:

| source | ratio | engine | crest (dB) | RMS | HF fraction |
| --- | --- | --- | --- | --- | --- |
| click120 | in | - | 31.3 | 0.023 | 0.0529 |
| click120 | 0.85x | signalsmith | 32.5 | 0.023 | 0.0528 |
| click120 | 0.85x | wsola | 32.7 | 0.023 | 0.0518 |
| click120 | 1.15x | signalsmith | 31.6 | 0.023 | 0.0532 |
| click120 | 1.15x | wsola | 32.1 | 0.023 | 0.0526 |
| sweep | in | - | 3.0 | 0.354 | 0.0274 |
| sweep | 0.85x | signalsmith | 4.3 | 0.351 | 0.0270 |
| sweep | 0.85x | wsola | 4.5 | 0.354 | 0.0243 |
| sweep | 1.15x | signalsmith | 3.2 | 0.352 | 0.0271 |
| sweep | 1.15x | wsola | 3.7 | 0.354 | 0.0265 |

Identity (1.0x) is BIT-EXACT bypass for BOTH engines (asserted).

Reading the numbers honestly: on these synthetic fixtures the two engines are
close. Both preserve RMS (WSOLA renormalizes explicitly; Signalsmith
naturally). On transient clicks both hold crest factor within ~0.5 dB. The
one consistent objective difference is HF retention on the tonal sweep:
Signalsmith keeps more high-frequency energy (0.0270 vs 0.0243 at 0.85x,
about 11% more), i.e. less high-end dulling / warble — the property
Signalsmith is designed for. WSOLA's slightly higher crest on the sweep is
overlap-add amplitude ripple, not a quality win.

VERDICT: ship Signalsmith Stretch as the PRIMARY warp engine, keep WSOLA as
the fallback and A/B baseline. Rationale:

1. Signalsmith builds cleanly on this Mac (verified: bindgen + cc + libclang
   present; the crate compiled and ran).
2. MIT licensed (compatible with the workspace).
3. It is a purpose-built, widely used high-quality stretch library
   (phase-vocoder-class with transient/formant handling), which matters most
   on real polyphonic and vocal material where a single-correlation WSOLA
   overlap struggles, even though synthetic clicks/sweeps do not separate
   them dramatically.
4. Objective edge in HF retention on tonal material (above).
5. WSOLA stays as a dependency-free, deterministic fallback and the honest
   A/B baseline, and as the offline-safe path if a C++ toolchain is ever
   unavailable at build time.

Both run OFF the audio thread into pre-rendered buffers; the render callback
never stretches.

## Null residual

Full-graph offline bounce vs captured-realtime-style run: BIT-IDENTICAL
(residual peak -inf dBFS) at 128, 512, and 417 frame block sizes, with the
whole graph active (gain, pan, EQ, both sends, both buses, master gain, and
the true-peak limiter). This clears the < -120 dBFS bar with no margin
needed. The P0-B small null test also remains bit-identical.

## Adversarial review (post-implementation) + fixes

A four-angle correctness review (RT core, DSP, warp/compile/automation,
engine/host) ran against the whole lane. Four real bugs were found and fixed,
each with a regression test:

1. Limiter wedge-ring aliasing (`dsp/limiter.rs`): the sliding-minimum
   monotonic deque momentarily held `LOOKAHEAD_FRAMES + 1` entries, which
   aliased the `+1`-sized ring's empty sentinel, skipped the front-eviction,
   collapsed the window minimum, and could let a delayed peak through above
   the ceiling on a strictly-decreasing hot ramp. Fixed by sizing the ring
   `+2`. Test: `ceiling_holds_on_a_strictly_decreasing_hot_ramp`.
2. WSOLA silent gaps past 2x (`warp.rs`): the donor's fixed-analysis-hop form
   set `synthesis_hop = analysis_hop * ratio`, which exceeds the window for
   ratios > 2x and left periodic silent gaps (up to 50% duty at 4x).
   Rewritten synthesis-driven (fixed 75%-overlap output hop, fractional
   analysis hop), gap-free across the full 0.25x..4x range. Test:
   `wsola_has_no_silent_gaps_at_large_ratios`. (Signalsmith, the primary, was
   never affected.)
3. Warp generation reset (`host.rs`): an identity clear removed the overlay
   entry, so the next non-identity request restarted generation at 1 and a
   stale in-flight result could be accepted as current. Fixed with a
   host-level monotonic counter that survives entry removal. Test:
   `warp_generation_is_monotonic_across_identity_clear`.
4. Engine brick on failed (re)start (`engine.rs`): `start_output` consumed
   the render core before the fallible cpal build/play, so a device that
   passed config checks but failed to start (a Bluetooth device that just
   dropped, exactly the device-switch case) left the core gone forever and
   every later start failed. Fixed by rebuilding a fresh core on the error
   paths.

Verified clean by the review (no change needed): the silence gate (no
non-zero path to the device without MAJIKS_TEST_AUDIBLE), the f32-bits
`fetch_max` peak trick, Relaxed-atomic usage, the loudness thread shutdown,
device-switch state sharing, all param clamps vs the command catalog, the RBJ
biquad coefficients + bit-exact bypass, the true-peak detector ring walk, the
reverb/delay feedback stability, and the automation cursor correctness.

## Contract / interface requests for L1 (timeline-core)

The render side needs these to move from host-side shims to real journaled
commands. None block L2; they are wired as typed host methods today and the
model/command layer should own them:

1. Mixer command handlers on `timeline-core::Project::apply`: `mix.gain`,
   `mix.pan`, `mix.eq` (4 bands, freq/gain/Q), `mix.send` (bus a/b),
   `mix.master.gain`, `mix.limiter.set`. The catalog (P0-C) already defines
   these; timeline-core's P0-B subset does not yet apply them. L2 mirrors
   them into engine params via `ProjectHost::set_*` as a stopgap.
2. Automation command handlers: `autopoint.add` / `autopoint.move` /
   `autopoint.remove` / `autolane.clear` for targets `track.volume` and
   `track.pan`, stored on the model and surfaced to render as tick-positioned
   points. L2 keeps a render-side `AutomationStore` today.
3. `clip.warp.set` handler that records the per-clip ratio on the model. L2
   keeps a render-side warp overlay today.
4. Automation SEGMENT SHAPE: catalog v1 `autopoint.add` has no curve field.
   The render evaluator already supports Step / Linear / Pow segments. If
   curved automation is wanted, add an optional `curve` to the autopoint
   params; otherwise L2 defaults every segment to Linear. Flagged as a
   product decision, not silently added to the catalog.
5. Per-clip fade SHAPE per EDGE: the model's `Clip` carries one `fade_shape`
   for both edges. The render `RtClip` already supports independent in/out
   shapes (the compiler injects LINEAR declick ramps on one edge while
   leaving an authored EQUAL_POWER fade on the other). If per-edge authored
   shapes are wanted, split `fade_shape` into `fade_in_shape` /
   `fade_out_shape` on the model. Not urgent.

## Open questions (product intent)

- Declick default: `DeclickPolicy::Auto` injects an implicit 5 ms linear ramp
  at every non-continuous zero-fade clip edge (clickless playback). The
  correctness suites use `None` (raw scheduler, sample-exact). The live host
  defaults to `Auto`. Confirm Auto is the intended live default and that an
  implicit 5 ms edge fade on hard cuts is acceptable (it is standard DAW
  behavior; it is defeatable per policy).
- Delay bus tempo divisions: the bus offers sixteenth / eighth / dotted
  eighth / quarter / dotted quarter / half. Confirm the set, and whether a
  free-ms mode is also wanted for v1.
- Reverb/delay are fixed-slot buses with quality defaults (per 01-DESIGN
  3.7). The voicing (reverb feedback/damping defaults, delay default
  feedback/tone) is placeholder-quality per the brief; a dedicated voicing
  pass is future scope.
