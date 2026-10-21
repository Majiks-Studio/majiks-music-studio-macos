# L4 evidence: Gen Protocol service

Lane: `lane/l4-gen-protocol`. Adapts the shipped ACE-Step generators behind the
frozen Gen Protocol v1 contract (`engine/contracts/gen-protocol.v1.yaml` +
`gen-protocol-mapping.md`) without changing any existing `generate_*` behavior.

Files owned by this lane:

- `src/python/majik_backend/gen_protocol.py` (new): the service.
- `src/python/tests/test_gen_protocol*.py` + `conftest.py` (new): the suite.
- `src/swift/Sources/GenProtocol/**` (new): `GenProtocolTypes.swift`,
  `GenProtocolCapabilityMerge.swift`, `GenProtocolClient.swift`.
- `src/swift/Tests/GenProtocolCapabilityMergeTests.swift` (new).
- `src/python/majik_backend/rpc_server.py`: four additive dispatch lines only
  (`gen.submit` / `gen.status` / `gen.cancel` / `gen.capabilities`), thin
  delegation, zero changes to any existing method body.

## Test tallies

- Python (this Mac, system `python3` is 3.14; a per-lane venv under the
  worktree with `numpy`, `soundfile`, `librosa`, `pytest`, `jsonschema`,
  `pyyaml`, `blake3`): `python3 -m pytest src/python/tests -k "not slow"` =>
  **173 passed, 2 deselected**. Full run (`pytest src/python/tests`) =>
  **173 passed, 2 skipped** (the two `slow` smokes skip: the real-local one
  needs torch/acestep, absent in a bare clone; the live-remote one is opt-in
  via env). The four gen_protocol test files alone: **168 passed, 2 skipped**.
- Swift (`swift test`, whole app target): **174 tests, all passed** (19 new
  GenProtocol suites: capability merge, client-over-stub, ULID + request; plus
  the 155 pre-existing tests, none broken). `swift build` clean.
- Regression gate (session adaptation): mocked pytest green + `pytest -k "not
  slow"` green + zero diffs to existing method behavior (existing
  `test_e2e_export.py` still passes; existing Swift suites still pass).

## 1. What each Gen Protocol op maps to (local-mlx route)

All ten ops adapt existing `ace_generator.py` methods per `gen-protocol-mapping
.md`. The service is an async job registry: `gen.submit` spawns a background
thread that calls the (unmodified) generator, re-emits its `progress_callback`
as `progress` notifications correlated by `jobId` (== the caller's
`requestId`), and records a terminal `JobRecord`. Local jobs serialize through
one lock (the singleton `ACEStepGenerator` is not concurrency-safe).

- generate -> `generate_music` (nVariants>1 -> `generate_variants`)
- revise -> `generate_repaint` + client-side splice (see section 3)
- extend -> `generate_continuation` + open-tail splice (keep original, append
  the new tail only)
- layer -> `generate_lego`
- retake -> polymorphic: region present -> `generate_repaint`, absent ->
  `generate_music`, both with a fresh seed. Needs a lineage lookup (below).
- autocomplete -> `generate_auto_complete`
- cover -> `generate_cover`
- separate -> `export_stems` (demucs) or `generate_extract` (ace-extract,
  labeled generative in lineage: its `engineIdentity.model` is an ACE-Step
  name, never `htdemucs`)
- analyze -> `understand_music` (full) or `analyze_audio_file` (fast).
  Synchronous per its own contract shape (200, not a 202 job).
- finalize -> `generate_repaint` at a quality rung, reusing the draft's own
  seed.

Terminal artifacts carry `{kind, path, contentHash}` where `contentHash` is a
blake3 hex digest, plus `engineIdentity {model, device, steps?, seed?}` for
lineage.

## 2. Observed capabilities matrix

`gen.capabilities` merges per endpoint. Values below are what the code actually
returns (Swift-side merge in `GenProtocolCapabilityMerge`, Python-side in
`gen_protocol.capabilities()`), grounded in code read + the live probe in
section 4.

| route | ops | how derived |
|---|---|---|
| local-mlx | generate, revise, extend, layer, retake, autocomplete, cover, separate, analyze, finalize | everything this lane's mapping implements; gated on `ace_generator` importing + `list_models()` working in the running environment |
| remote-ace | generate ONLY | structural fact from reading `RemoteACEStepGenerator` + `RemoteGenerationService.swift`: the `/api/v1/studio/generate` bridge carries text2music fields only (no `task_type`, `src_audio_path`, `repainting_start/end`, or instruction template). Verified by build-time inspection of `RemoteGenerationParams`, not a probe. So revise-class ops are local-only on this route. |
| gen-node | generate, revise, extend, layer, autocomplete, cover, finalize (NOT separate/analyze) | what P0-A proved the raw ACE-Step api_server wire protocol supports (`/release_task` JSON carries `task_type`/`repainting_*`); confirmed live (section 4). separate/analyze have no REST equivalent on the stock server. Empty + zero slots when `MAJIKS_GEN_NODE_URL` is unset or unreachable (graceful unknown). |
| uc-cloud | (none) | not implemented in this lane (no deployment, no credentials); reported present with an empty op list. |

Route caveat resolution (02-ARCH section 5): the caveat "the raw ACE-Step
api_server may expose only text2music" is resolved in the GOOD direction, but
only for the gen-node route (raw `/release_task`). The remote-ace route
(`/api/v1/studio/generate`, the existing Swift ServerPool bridge) genuinely is
text2music-only, so revise-class ops route local-mlx or gen-node, never
remote-ace. This is coordinated to P-00120 via this report, not built as a
gateway here.

Live-probed capability matrix (bigboy stock api_server on 8010, ACESTEP_INIT_LLM=false):

```
local-mlx:  ops=[]                                                   models=[]                                     slots=0   (bare bigboy ACE venv: torch/acestep absent, so ace_generator did not import; local execution unavailable there, as expected)
remote-ace: ops=['generate']                                        models=['acestep-v15-turbo']                  slots=0   (no ACE_STEP_SERVER_URL configured in the driver)
gen-node:   ops=['generate','revise','extend','layer','autocomplete','cover','finalize']  models=['acestep-v15-turbo','acestep-v15-base']  slots=1
uc-cloud:   ops=[]                                                   models=[]                                     slots=0
```

## 3. Client-side splice is mandatory (P0-A, implemented here)

Per `docs/evidence/p0a-repaint.md` sections 1/5/9: raw repaint/extend output
never preserves untouched audio (median about -21 dBFS residual outside the
region; normalization alone swings gain 0.19x-1.47x). So revise, region-retake,
extend, and finalize splice the model output back into the original outside the
edited region/span. Splice is a 20 ms equal-power crossfade placed INSIDE the
region (P0-A section 9 default), mirroring the validated approach in
`tools/repaint_harness/splice.py`. Stem-scope revises separate the
region+context window (not the full song) with the existing `export_stems`,
splice only the scoped stems, null-preserve the rest.

Live proof (section 4 revise output, region 8.0..16.0 s of a 30 s clip):

```
OUTSIDE region max abs residual (pre): 0.0  (post): 0.0   -> bit-exact (null-preserve)
INSIDE  region RMS diff vs source:     0.12414             -> repaint content present
```

## 4. Live smoke transcript (real remote route)

Executed 2026-07-12. Boot: `ssh muut@bigboy` (100.126.207.157, tailnet), then
`cd ~/models/ACE-Step-1.5 && ACESTEP_INIT_LLM=false ./.venv/bin/python -m
acestep.api_server --host 127.0.0.1 --port 8010` (detached). Readiness confirmed
via `/health`: `models_initialized: true, llm_initialized: false, loaded_model:
acestep-v15-turbo`. GPU 0 before: 313 MiB (only an unrelated `/app/llama-server`
at 306 MiB, far below the 2 GB skip threshold, so the 3090 was free). GPU 1 not
touched. Driver ran `gen_protocol.py`'s gen-node route pointed at
`http://127.0.0.1:8010` from the bigboy side (shared filesystem so `src_audio`
server-side paths resolve; the ACE venv has numpy+soundfile, enough for the
gen-node path; `ace_generator` degraded gracefully, `_HAVE_ACE_GENERATOR=False`).

ONE gen.submit generate (30 s clip, the generateRequest minimum duration; an
"8-bar-class" short smoke, wav32, turbo/8, seed 1234):

```
submit -> {"jobId": "01ARZ3NDEKTSV4RRFFQ69G5FAV"}
status: running -> downloading 85% -> done
artifact kind=mix blake3=5d5c25f28c08f1bd0eb4ba2ddff10a8c6f0b26ba9060b27af0daefdbad698843
engineIdentity={"model":"acestep-v15-turbo","device":"remote","steps":8,"seed":1234}
```

ONE gen.submit revise / repaint (region 8.0..16.0 s = a 4-bar-class window of
the generated clip, base/50, seed 5678, all-stems, client-side splice; the
server swapped its DiT turbo->base to serve the repaint):

```
submit -> {"jobId": "01BX5ZZKBKACTAV9WEVGEMMVRZ"}
status: running -> downloading 85% -> done
artifact kind=mix blake3=17cd8db6b27d2f6fad2a2feb42826b3e3d333dedb2fea9e3e2d5827d3541e0fe
engineIdentity={"model":"acestep-v15-base","device":"remote","steps":50,"seed":5678}
```

Splice verification (numpy, bigboy): shown in section 3 (bit-exact outside the
region, changed inside). Both ops reached terminal `done` with artifact path +
blake3 hash + engine identity, i.e. the full job lifecycle
submit -> progress -> terminal + lineage, exercised against a real stock
api_server.

Teardown: `./close_api_server.sh --port 8010` (stopped PID 565943; NEVER
`pkill -f acestep`, which would match the ssh session). Port 8010 freed.
`~/models/ACE-Step-1.5/.cache/acestep/tmp/api_audio` cleaned. GPU 0 back to
313 MiB (only the pre-existing llama-server), 0% util. `/tmp/l4smoke` staging
and smoke outputs removed.

### Bug the smoke caught (fixed)

First run failed at download with HTTP 403. Root cause: the stock server's
`/query_result` returns `file` as a READY, percent-encoded server-relative
download URL fragment (`/v1/audio?path=%2Fhome%2Fmuut%2F...%2Fclip.wav`), not a
bare path. The client wrapped it in a SECOND `/v1/audio?path=` layer, which
double-encoded it, so the server's `temp_audio_dir` path check resolved a nested
non-file string and 403'd. Fixed `_StockAceServerClient.get_bytes` to use a
ready URL/fragment as-is and only wrap a bare filesystem path. The mock server
in `test_gen_protocol_gen_node.py` was updated to reproduce the real wire shape
(returns `file` as a `/v1/audio?path=` fragment AND 403s a path that is not the
served file), plus three explicit `get_bytes` regression tests, so this cannot
slip back.

## 5. Architecture notes and decisions (flagged, not silently taken)

- The Swift `GenProtocolClient` proxies EXECUTION for every route to the Python
  `gen.*` RPC, and WRAPS the Swift ServerPool + `RemoteGenerationService`
  (without editing them) for the CAPABILITY side (remote-ace availability +
  models). Rationale: terminal artifact hashes are blake3, and Python owns the
  one blake3 implementation in this program; Python's `RemoteACEStepGenerator`
  speaks the identical `/api/v1/studio/generate` protocol as
  `RemoteGenerationService`, so routing remote-ace execution through Python
  changes no remote wire behavior and keeps lineage hashing in one place. A
  future lane could add a direct-Swift remote fast-path (live progress) once a
  Swift blake3 or a hash-registration RPC exists.
- `JSONValue` (existing, not owned by this lane) needed a `Sendable`
  conformance to cross the new `GenProtocolRPCSending` boundary. It is a pure
  value enum, genuinely Sendable; the conformance is added in this lane's own
  `GenProtocolTypes.swift` as `extension JSONValue: @unchecked Sendable {}`
  (`@unchecked` is required because a checked conformance must live in the
  type's own file). Marker-only, no runtime effect, cannot change existing
  behavior; `JSONValue.swift` itself is untouched.
- gen-node payloads apply two P0-A findings on this NEW route only (local-mlx
  untouched): `chunk_mask_mode="explicit"` for repaint (P0-A section 2 finding
  #3, about 8 dB better outside-region fidelity, no seam cost), and leaving the
  wire `instruction` field unset so the server's own `_resolve_instruction()`
  fills the correct `TASK_INSTRUCTIONS[task_type]` (P0-A finding #1); lego uses
  `track_name` so the server builds the canonical lego template (finding #4).
  gen-node also forces `batch_size=1` (the server default 2 would silently
  double every call) and `thinking=false` (no LM needed for a caption->DiT
  call; keeps the route usable with `ACESTEP_INIT_LLM=false`).

## 6. Open questions / proposals for other lanes

1. retake needs a lineage resolver: sourceTakeId -> the take's originating
   request (source audio, region, caption). That store is the Rust engine's
   journal / `takes.list` / `lineage.get(clipId)` (02-ARCH section 4), which
   does not exist yet (L1 territory). The service fully implements retake's
   routing/validation but takes an injectable `lineage_resolver`; with none
   configured it raises `LINEAGE_STORE_NOT_AVAILABLE` rather than inventing a
   lookup. A later lane should wire this once the takes read-surface exists.
2. `targetQualityRung="standard"` (acestep-v15-quality) has no confirmed step
   count in any shipped call site (already flagged in `gen-protocol-mapping.md`).
   This lane does NOT invent one: finalize with rung=standard raises
   `QUALITY_RUNG_NOT_CONFIGURED`. Propose confirming the step count or dropping
   the rung to draft/full at the next contract revision.
3. analyze `downbeats` and `loudnessLufs` are always null (no producer in the
   Python backend; loudness is planned for the Rust engine's media crate). The
   contract already marks both nullable; this stays a known gap until a
   producing lane lands.
4. The Swift remote-ace availability probe reports empty `models` for now (a
   synchronous probe does not block on network to sweep each server's
   `/v1/models`). A background health/model sweep (existing ServerPool pattern)
   should populate it; the merge already unions whatever it is given.
5. lego can produce any named instrument layer, but the artifact `kind` enum is
   fixed to {mix, vocals, drums, bass, other}. The service best-effort matches
   the instruction to a named stem, else `other`. Propose a free-text lego kind
   at the next contract revision if that loses useful lineage detail.
6. Local-mlx concurrency: `gen.submit` serializes local jobs through one lock,
   but cannot cover old-style direct `generate_*` RPC calls made concurrently
   (those dispatch blocks are outside this lane's file ownership). Not an active
   risk today (nothing wires `gen.submit` into the shipping Create tab, and
   `GenerationQueue.swift` already serializes local jobs client-side). Whoever
   wires `gen.submit` into the Studio tab should confirm single-flight locally.
