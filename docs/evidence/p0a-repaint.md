# P0-A evidence: repaint reality harness

Lane: `lane/p0a-repaint-harness`. Harness code: `tools/repaint_harness/`.
Executed 2026-07-11 on bigboy (RTX 3090 24 GB, torch 2.10.0+cu128, ACE-Step 1.5
at `~/models/ACE-Step-1.5`, LM backend `pt`, `acestep-5Hz-lm-1.7B`).
Analysis venv: corpus-pipeline (librosa 0.11, demucs 4.0.1, htdemucs_ft).
36 generation ops, 0 failures. Audition set delivered to
`~/Desktop/majiks-daw-p0a-audition/` (20 WAVs + READ-ME-FIRST.txt).
Raw numbers: `out/manifest.json` + `out/analysis.json` on bigboy
(`~/daw-p0a/`), tables renderable with `python -m repaint_harness.report`.

Headline numbers:

1. Raw repaint output does NOT preserve untouched audio: median residual
   outside the region is about -21 dBFS RMS (best -29.9, worst -12.5)
   across 33 repaint ops. Client-side splicing is mandatory, always.
2. Spliced seams can sit at the unedited song's own floor: best take
   click ratio 11.8 vs 11.3 baseline, spectral flux z-score -0.35; the
   stem-scoped (drums+other) render measured 3.4/8.0 vs floors 3.3/11.3.
3. Honest 3090 latency for a 112 s song: 3.9 s draft repaint (turbo 8),
   15.7 s commit repaint (base 50, app default), +2.0 s htdemucs_ft on
   the region for stem-scoped revises. Cost scales with song length, not
   region length.

## 1. Capability answer: does acestep.api_server expose repaint over REST?

YES. The stock ACE-Step 1.5 REST server is NOT text2music-only. Read from
source on the deployed install (`acestep/api_server.py` and `acestep/api/`):

- `POST /release_task` accepts `application/json`,
  `application/x-www-form-urlencoded`, and `multipart/form-data`
  (`acestep/api/http/release_task_request_parser.py`).
- The request model `GenerateMusicRequest`
  (`acestep/api/http/release_task_models.py`) carries `task_type`
  (default "text2music"), `src_audio_path`, `repainting_start`,
  `repainting_end`, `instruction`, `reference_audio_path`,
  `audio_cover_strength`, `cover_noise_strength`, `track_name`,
  `track_classes`, `model`, `inference_steps`, `seed`, and
  `audio_format` (flac, mp3, opus, aac, wav, wav32).
- `acestep/api/job_generation_setup.py` maps all of these into
  `GenerationParams`, including `task_type=req.task_type`,
  `src_audio=req.src_audio_path`, `repainting_start/end`, and resolves the
  task-specific instruction from `TASK_INSTRUCTIONS` when the client leaves
  the default.
- `acestep/constants.py`: `TASK_TYPES = ["text2music", "repaint", "cover",
  "extract", "lego", "complete"]`. Turbo checkpoints are declared for
  `["text2music", "repaint", "cover"]` (`TASK_TYPES_TURBO`); base and XL
  checkpoints declare all six.
- Source audio can be sent as a server-side path (validated) or uploaded
  as a multipart file that lands in a temp dir
  (`release_task_audio_paths.py: save_upload_to_temp`).

Consequence for Phase 1: the remote/Gen Node route can carry revise-class
ops (repaint, extend, lego, extract, cover) over the raw api_server today.
The route caveat in 02-ARCHITECTURE.md section 5 ("may expose only
text2music") is resolved in the good direction. The client must upload the
source audio (or reference a server path); job flow is `release_task` then
`query_result` polling, and results come back as `/v1/audio?path=...`
download URLs.

One wrinkle to carry into L4: the aliasing table in
`release_task_param_parser.py` (used for form-encoded and `param_obj`
payloads) has no aliases for `repainting_start`, `repainting_end`, or
`instruction`. JSON bodies bind them via the pydantic model, so send
repaint requests as `application/json`.

## 2. What the app backend actually sends (found while mirroring it)

The harness mirrors `src/python/majik_backend/ace_generator.py` parameter
for parameter, and that surfaced four app-side behaviors worth product
attention (no app code was changed in this lane):

1. `generate_repaint` leaves `GenerationParams.instruction` at the
   text2music default ("Fill the audio semantic mask based on the given
   conditions:") instead of `TASK_INSTRUCTIONS["repaint"]` ("Repaint the
   mask area based on the given conditions:"). `acestep.inference` does NOT
   auto-resolve by task type; the REST server does. Probe measured below.
2. `generate_repaint` leaves `enable_normalization` True (-1 dBFS peak), so
   the whole returned track is re-normalized. Measured gains ranged 0.19x
   to 1.47x across takes, which by itself breaks any hope of using raw
   output outside the region.
3. `generate_repaint` leaves `chunk_mask_mode` at "auto" (mask all 2.0,
   model decides). "explicit" (0/1 mask from the repaint range) preserved
   the outside-region audio about 8 dB better (see probes).
4. `generate_lego` passes the bare instrument word (e.g. "bass") as the
   whole instruction; the canonical template is "Generate the BASS track
   based on the audio context:". The harness lego op used the canonical
   form and it worked well.

## 3. Test material

Two songs generated on the 3090 via the pipeline (turbo, 8 steps, wav32,
48 kHz stereo, thinking=True with the 1.7B LM, fixed seeds):

| song | genre | declared | duration | seed | revised region |
|---|---|---|---|---|---|
| A | indie rock, male vocals | 120 bpm, E minor, 4/4 | 112.0 s | 101 | bars 17-24 = 32.0-48.0 s |
| B | neo-soul, female vocals | 96 bpm, F major, 4/4 | 110.0 s | 202 | bars 13-20 = 30.0-50.0 s |

Both regions contain lead vocals. Repaint ops resend the identical full
lyrics ([verse]/[chorus] tags), i.e. "keep lyrics" on.

Finding (tempo truth): the generated audio does NOT run at exactly the
declared BPM. Least-squares fit over about 200 tracked beats (hop 128,
which removes librosa's integer-lag quantization): song A actually runs
about 118.6 bpm (beat period +1.2% vs declared), song B about 93.3 bpm
(+2.9%). Bar boundaries computed from declared BPM therefore sit up to
about 0.4 s (A) and 0.9 s (B) off the true grid at the region start. The
harness kept declared-BPM boundaries on purpose: that is what a v1 Revise
UI would do with the metadata it has, so every seam metric below includes
this real misalignment. Product consequence in the verdict.

Also structural: ACE-Step latents run at 25 Hz, so repainting_start/end are
quantized to 40 ms inside the model no matter what seconds the caller sends.

## 4. Boundary metrics: repaint matrix

18 takes on song A (3 instructions x 3 seeds x {base, xl-base}, 50 steps,
app repaint defaults) + 3 takes on song B (base). Full per-op table via
`repaint_harness.report`; summary of the 20 ms splice seams, worst of the
two boundaries per take:

- Baseline floors (the SAME positions in the unedited songs):
  song A click 3.3 (region start) and 11.3 (region end), flux z -0.4/-0.8;
  song B click 1.6/7.8.
- click ratio: 9.0 to 21.1 across takes (A), best takes at the floor.
  The click metric is dominated by musical transients near the boundary,
  not by cut glitches, once any fade is applied.
- spectral flux z-score: -0.35 to +2.14. 14 of 21 takes land below +1.0,
  i.e. the seam is no more spectrally abrupt than the song's own typical
  frame transitions.
- RMS step: 0.2 to 5.5 dB. The big steps belong to takes that actually
  changed dynamics as instructed (half-time drums are quieter). This is
  musical intent, not a defect metric.
- Tempo: repainted regions preserve the source's measured beat period
  (drift +2.40%, identical to the original region) in every take where the
  beat tracker locked normally. Two takes read near +100% because the
  content genuinely went half-time (tracker octave), which is the
  instruction working. No take broke the grid.
- Seed dominates instruction: take-to-take spread within one instruction
  (seeds 11/22/33) is larger than the spread between instructions. Seed 22
  produced the cleanest seams on song A in all three instruction variants;
  seed 33 the roughest. This is why the Revise UI's default of 3 variants
  is correct product design: the user picks the take, takes are cheap.
- base vs xl-base at the seams: no systematic XL win (flux z means are
  comparable; XL slightly tighter on the roughest seed). XL costs 2.1x
  wall time. XL vs base is a mid-region taste question for ears, not a
  boundary-quality question.

Probes (one knob at a time off the halftime/seed-11/base-50 twin):

| probe | outside-region residual (strict) | note |
|---|---|---|
| app defaults (twin) | -20.9 dB | |
| enable_normalization=False | -21.0 dB | gain was near 1.0 on this take; on other takes normalization alone scaled everything by up to 14 dB |
| chunk_mask_mode="explicit" | -28.8 dB | 8 dB better outside fidelity |
| canonical repaint instruction | -21.9 dB | no seam-metric change; content adherence is an ears question |
| all three combined | -28.9 dB | best outside fidelity of the whole matrix |

## 5. Null test outside the region

Raw repaint output vs the source, everything except the region compared
sample-aligned (strict, no guard; a 250 ms guard changed nothing):

- All 33 repaint ops: residual RMS between -12.5 and -29.9 dBFS,
  median about -21 dB. After optimal scalar gain compensation: -17.4 to
  -29.9 dB. NEVER silence.
- Cause: the whole track goes through the 25 Hz latent VAE round trip and
  a full-track loudness renormalization. "Untouched" audio comes back as a
  lossy re-synthesis at roughly -20 dB residual, which is audible as
  spectral smearing, and the per-take gain swings (0.19x to 1.47x) are
  plainly audible level changes.

Rule this locks in (assumed by 01-DESIGN 3.2, now measured): the DAW must
NEVER present raw repaint output outside the region. Commit = splice the
region into the ORIGINAL waveform with crossfades. The harness splice
(fades inside the region) keeps outside audio bit-exact by construction.

The same applies to extend: the complete op rewrote the original 112 s
span at -14.2 dB residual. Extend commits must keep the original audio
and splice only the new tail.

## 6. Stem-scope splice (the product rule from 02-ARCH section 5)

Pipeline executed on the best matrix take (halftime, seed 22, base 50):
repaint the mix region, separate the repainted region + 1 bar context each
side with htdemucs_ft, splice ONLY drums+other stems over the original
stems (20 ms fades), keep vocals+bass original everywhere, sum.

| measure | value |
|---|---|
| seam at region start | click 3.4 (floor 3.3), flux z -0.31 |
| seam at region end | click 8.0 (floor 11.3), flux z -0.68 |
| RMS step at start | 4.2 dB (the half-time instruction, intended) |
| null vs original stem sum, outside region | exact (-200 dB, by construction) |
| whole-track cost vs original mix | -39.0 dB (htdemucs_ft reconstruction error) |
| tempo in region | +2.40% drift, same as source |
| separation time, region + context (20 s) | 2.0 s (htdemucs_ft), 0.85 s (htdemucs) |
| separation time, full song (112 s) | 12.2 s (htdemucs_ft) |

Verdict on the pipeline: musically clean enough to ship behind the Revise
UI. Both seams measured at the unedited floor, better than the plain mix
splice, because the unscoped stems carry continuity straight through the
seam. The one systemic cost: when a track enters stem scope, everything
outside the region in the DRUMS/OTHER lanes is a demucs reconstruction
(-39 dB vs the true mix). Two consequences for the engine lane:
(a) only pay the stems detour when scope != all, (b) when stems for a
track already exist (Stem Sessions), splice into those instead of
re-separating.

The demucs CLI could not run in the analysis venv (torchaudio pulls
torchcodec, whose shared library fails to load). The harness falls back to
the demucs Python API with soundfile I/O and identical normalization
(`analyze_stage._demucs_api`). Same weights, same math; keep this in mind
if timings are ever compared against `python -m demucs` elsewhere.

## 7. Steps ladder and the draft/commit recommendation

Same region, same seed (11), same halftime instruction, 20 ms splice.
Wall is the whole repaint op on the 3090 (model already resident):

| rung | wall s | flux z (worst boundary) | click | notes |
|---|---|---|---|---|
| turbo 8 | 3.9 | 0.20 | 18.6 | cleanest flux in the ladder |
| base 10 | 5.6 | 0.73 | 20.7 | audible low-step texture, see audition |
| base 20 | 8.1 | 1.58 | 7.2 | |
| base 50 | 15.7 | 0.78 | 18.3 | app default |
| xl 10 | 8.9 | 0.46 | 7.3 | |
| xl 20 | 14.8 | 0.18 | 29.6 | |
| xl 50 | 32.7 | 0.98 | 19.9 | |

Recommendation:
- DRAFT rung: turbo 8. 3.9 s per take, seam metrics at or better than
  base 50, and turbo officially supports repaint (TASK_TYPES_TURBO).
  Render audition takes with turbo 8, full-song context.
- COMMIT rung: base 50 (the app default) at 15.7 s, pending Aaron's ear on
  the ladder files; nothing in the boundary numbers justifies XL's 2.1x
  cost, so XL stays an advanced engine override.
- Region-trimmed drafts (repaint a clip of region + 1 bar context instead
  of the whole song): NOT recommended as the default. base 50 trimmed cut
  wall time 15.7 to 4.0 s but produced the worst level adherence of the
  entire matrix (10.4 dB step, audition file included); turbo 8 trimmed
  measured fine at 1.3 s but only saves 2.6 s over full-context turbo.
  Keep the trimmed path as a length-scaling escape hatch for long songs
  (cost scales with song length: turbo 8 is about 3.5% of song length),
  not as the default draft.

## 8. Latency table

RTX 3090, CUDA, LM = 1.7B (pt backend), song = 112 s unless noted.
Wall-clock is the full pipeline call including LM hints and VAE decode.
One-time costs: DiT load 2.2-10.5 s (turbo about 5 s, base 2-5 s, XL
5-10 s), LM load about 28 s per backend process.

| op | model | steps | wall s |
|---|---|---|---|
| generate (text2music, 112 s song) | turbo | 8 | 20.0 |
| repaint (any region size) | turbo | 8 | 3.9 |
| repaint | base | 10 | 5.6 |
| repaint | base | 20 | 8.1 |
| repaint | base | 50 | 15.7 (mean of 16 ops, sd about 0.2) |
| repaint | xl-base | 50 | 32.7 (mean of 8 ops) |
| repaint, 20 s trimmed clip | base | 50 | 4.0 |
| repaint, 20 s trimmed clip | turbo | 8 | 1.3 |
| extend +16 bars (to 144 s) | turbo | 8 | 25.0 |
| lego layer (112 s) | base | 50 | 31.2 |
| separate region + context (20 s) | htdemucs_ft | | 2.0 |
| separate region + context (20 s) | htdemucs | | 0.85 |
| separate full song (112 s) | htdemucs_ft | | 12.2 |

Per 8-bar region: repaint cost is INDEPENDENT of region size; it scales
with song length (the whole 25 Hz latent sequence is processed). For a
2 min song: draft take about 4 s, commit about 16 s, stem-scope adds about
2 s. Quote latency in the UI as a function of song length, not bars.

Mac MLX path: n/a this session. The Mac's system Python is 3.14 where
torch segfaults, and no MLX venv exists on this machine; the app's own
backend is the right harness for that measurement later (same
GenerationParams, device mps).

Note on text2music vs repaint speed: generate (20.0 s) is slower than
repaint (15.7 s) at 5x the steps difference because text2music spends the
LM budget generating a whole song of codes while repaint reuses source
codes outside the mask. LM chain-of-thought dominates turbo-class ops.

## 9. Verdict (the questions the brief asks, answered plainly)

For "revise bars 33-48, drums only": repaint + re-separate + splice IS
musically clean enough to ship behind the Revise UI. Measured seams of the
stem-scoped render sit at the unedited song's own boundary floor, unscoped
stems are bit-preserved outside the region and original-take inside it,
and tempo continuity matches the source. Present it WITH takes (default 3)
because seed variance dominates instruction variance; Revise and
regenerate-section-with-takes are the same feature in this design, so no
fallback posture is needed. Two honesty requirements in the UI copy:
(a) stem-scoped revises put the affected track's out-of-scope lanes
through a separation round trip unless stems already exist, and (b) no
"keep melody" toggle; nothing measured here supports melody preservation
claims.

Crossfade: 20 ms equal-power, placed inside the region, is the right
default. Fades change click energy barely at all (content transients
dominate) but spectral abruptness falls monotonically with fade length;
50 ms measurably calmed the roughest takes and never hurt, so expose 50 ms
as the escalation (or auto-pick when the seam measures hot). Even the hard
cut was not broken on good takes, which is why commit should never block
on fade tuning.

Latency to display honestly (3090-class local GPU, 2 min song): about 4 s
per draft take, about 16 s for the committed re-render, +2 s separation
when scope != all stems. The draft/commit two-phase render in 01-DESIGN
3.2 is validated: draft on turbo 8, commit on base 50 in the background.
Cost scales with song length, not selection length. Mac-local (MLX)
numbers still owed by a later lane.

The one prerequisite finding: declared BPM is not ground truth (1.2-2.9%
slow on both test songs), so bar-snapped Revise MUST snap to a measured
beat grid (beat-track on generate/import, store the tempo map in the
project). Region seconds derived from declared BPM put seams up to about
half a second off the true bar lines; everything above was measured under
that realistic error and survived it, but the UX promise "bars 33-48"
requires the measured grid.

## 10. Open questions and follow-ups for other lanes

1. App backend (separate small lane, no behavior changed here): send
   chunk_mask_mode="explicit" for repaint (8 dB better outside fidelity),
   decide on the canonical repaint instruction (no seam cost; possible
   adherence gain), splice client-side for repaint AND extend commits,
   and revisit lego's bare-word instruction vs the canonical template.
2. Scope=vocals revises: untested here. Repaint regenerates vocals inside
   the region; keep-lyrics was on (identical lyrics resent) and vocal
   re-entry at seams sounded continuous in the mix files, but a
   vocals-scoped splice (keep new vocals, preserve band) needs its own
   listening pass, and "change the lyrics of bars 17-24" is a different
   test matrix.
3. htdemucs_ft vs htdemucs stem QUALITY for the scoped splice was not
   compared (only timing, 2.4x). P-00121 owns the shared-model decision;
   at 2.0 s per region ft is affordable, so nothing here pressures D2.
4. Does repaint quality change when the region grid offset error grows
   (song B was 2.9% off vs A 1.2%)? B seams measured fine, but a
   deliberately misaligned-region experiment would isolate it.
5. bigboy corpus venv: torchaudio/torchcodec shared-library load is
   broken, which kills the demucs CLI there. Harness has an API fallback;
   the venv itself should get fixed or pinned eventually.
6. The 5 Hz LM hint path prints "Using precomputed LM hints" per op;
   this is model-internal (25 Hz hints), not a cross-op cache, so the
   latency table is honest per op.
