# Gen Protocol v1 to backend mapping

This is the authoritative field-by-field mapping from `gen-protocol.v1.yaml` /
`gen-protocol.schemas.json` onto the existing Python backend, read directly from
`src/python/majik_backend/ace_generator.py` and `src/python/majik_backend/rpc_server.py`
at `majiks-music-studio-pro@1869a5e`. Nothing below is invented: every backend
column is a real parameter name or RPC method name that exists in the code today.
Where a protocol field has no backend equivalent, or a backend behavior has no
clean protocol equivalent, that is called out explicitly rather than papered over.

Three layers, not two:

1. **Gen Protocol field** (this contract): what a caller (engine agent-surface,
   MCP tool, UI) sends.
2. **RPC wire param** (`rpc_server.py`'s `params.get(...)` calls): what actually
   crosses the JSON-RPC boundary to Python today. This is frequently NOT the same
   name as the Python method signature (e.g. wire `model` vs. Python
   `model_name`).
3. **Python method param** (`ace_generator.py` method signatures): what
   `ACEStepGenerator`/`RemoteACEStepGenerator` actually accept.

The engine's Gen Protocol service is the thing that translates layer 1 into layer
2 calls. Layer 2-to-3 translation already exists and is not this lane's concern;
it is included here only so the full chain is auditable in one place.

## Job identity and the async model

- `jobId` in every Gen Protocol response is **the same value** as the
  `requestId` the caller supplied in the request body. It is not a second id
  minted by the server. This matches the command catalog's "every command
  idempotency-keyed by id" acceptance hook (02-ARCH section 4): the same id
  threads from the journaled `gen.*` command's `requestId`, through the Gen
  Protocol `jobId`, to the `gen.landed` entry's `requestId`.
- **local-mlx route**: the current backend has no submit/poll job store for
  local generation. A JSON-RPC request (e.g. `generate_repaint`) blocks until
  done; progress arrives as JSON-RPC notifications
  (`{"jsonrpc":"2.0","method":"progress","params":{"id":<request id>,"stage":...,
  "percent":...,"message":...,"variant":...}}`, sent by `_progress()` /
  `_send_notification()` in `rpc_server.py`) correlated by the outer JSON-RPC
  request `id`. The Gen Protocol's submit/progress/terminal shape is the engine's
  NORMALIZATION of this: the engine mints/echoes `jobId` = the caller's
  `requestId`, uses it as the JSON-RPC `id` when it calls Python, and re-emits
  each `progress` notification as a `progressEvent` with `jobId` set from
  `params.id`. The terminal state is synthesized when the blocking RPC call
  returns (`done` on a `{"result": ...}` response, `failed` on an `{"error":
  ...}` response) or when `GenerationCancelled` propagates (`cancelled`).
- **remote-ace route** (`RemoteACEStepGenerator`): genuinely async already.
  `POST /api/v1/studio/generate` with body `{"params": {...}}` returns
  `{"id": task_id}`; the backend then polls `GET /api/v1/studio/jobs/{task_id}`
  every 2 seconds until `status` is `completed`/`complete` (-> `done`) or
  `failed`/`error` (-> `failed`). This is the closest existing precedent for the
  Gen Protocol's own `GET /gen/jobs/{jobId}` polling path.
- **gen-node / uc-cloud routes**: per 02-ARCH section 5's route caveat, if the
  Gen Node gateway lacks repaint/lego/extract endpoints, revise-class ops route
  local (MLX) until it grows them. Not this lane's concern to resolve, only to
  leave room for in the contract (the `route` field on every request schema is
  optional; omitting it lets the ServerPool choose).
- **Error shape**: every terminal `failed` state's `error` field reuses the
  existing `_structured_error()` vocabulary verbatim: `code` (a string, e.g.
  `OUT_OF_MEMORY`, `CHECKPOINT_MISSING`, `FILE_NOT_FOUND`, `CANCELLED`,
  `DISK_FULL`, `ACE_STEP_NOT_FOUND`, `MODEL_NOT_FOUND`,
  `REMOTE_GENERATION_FAILED`, `REMOTE_SERVER_ERROR`, `AUDIO_ANALYSIS_FAILED`,
  `EXTRACTION_FAILED`, `PYTHON_CRASH`), `message`, `fix`, optional `detail` and
  `step`. This is not a closed enum in the schema because `_categorize_exception`
  in `rpc_server.py` derives codes from exception text in a few fallback cases;
  the set above is what is reachable from the gen.* code paths specifically.

## Per-op mapping

### generate -> `generate_music`

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `caption` | `caption` | `caption` | required |
| `lyrics` | `lyrics` | `lyrics` | |
| `durationSeconds` | `duration` | `duration` | wire clamps to 30..600 |
| `bpm` | `bpm` | `bpm` | |
| `key` | `key` | `key` | |
| `timeSig` | `time_signature` | `time_signature` | default `"4"` |
| `vocalLanguage` | `vocal_language` | `vocal_language` | |
| `seed` | `seed` | `seed` | |
| `model` | `model` | `model_name` | **name differs**: wire key is `model`, Python param is `model_name`. Default `acestep-v15-turbo`. |
| `steps` | `num_inference_steps` | `num_inference_steps` | default 8 (turbo) |
| `nVariants` | `count` | n/a (dispatch) | **name differs and changes call target**: wire key is `count` (1..5, clamped). `count<=1` calls `generate_music` (single); `count>1` calls `generate_variants` (batch; also jitters bpm by up to `+/-2*index` semitones-equivalent and key by `_shift_key(key, index)` per variant, in addition to a `base_seed+index` seed — this is more than a plain seed sweep, see "generate_variants is not the retake primitive" below). |

Response: `{"result": {"audio_path": ..., "metadata": {...}}}` for `count<=1`;
`{"result": {"variants": [{"audio_path":..., "metadata":{...}}, ...]}}` for
`count>1`. `metadata` includes `file_path, duration, sample_rate, caption, lyrics,
seed, model, bpm, key`, plus `memory_estimate` and `detected_ram_gb` attached by
the RPC layer (not by `ace_generator.py`).

### revise -> `generate_repaint`

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `sourceAudioRef` | `source_audio` | `source_audio` | engine resolves the protocol's clip/asset reference to a filesystem path before calling; required, must exist |
| `regionStartSeconds` | `repainting_start` | `repainting_start` | default 0.0 |
| `regionEndSeconds` | `repainting_end` | `repainting_end` | default -1.0 = end of track |
| `instruction` | `caption` | `caption` | **name differs, called out explicitly in 02-ARCH section 5**: "instruction -> caption delta" |
| `seed` | `seed` | `seed` | |
| `model` (implicit) | `model` | `model_name` | default `acestep-v15-base` (NOT turbo) |
| `steps` (implicit) | `num_inference_steps` | `num_inference_steps` | default **50**, not 8. This is the "honest latency" default 02-ARCH section 5 calls out. |
| `variants` | n/a | n/a | **no backend batch primitive**: `generate_repaint` has no `count`. `variants > 1` means the engine issues that many sequential `generate_repaint` calls with incrementing seeds, same instruction/region. |

`scope != all-stems` (the stem-scope pipeline, 02-ARCH section 5): repaint the
mix region with surrounding context via the call above, then call
`export_stems` (htdemucs) on the repainted region, splice only the requested
stem(s) into the multitrack result, leave the rest byte-identical to the
pre-revise audio (null-preserved), and record a per-stem hash in the resulting
`gen.landed` entry's `assetHashes`. This pipeline composition is a Gen Protocol
service responsibility; no single backend call implements it.

### extend -> `generate_continuation`

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `sourceAudioRef` | `source_audio` | `source_audio` | required, must exist |
| `addedDurationSeconds` | `duration` (derived) | `duration` (derived) | **not a direct pass-through**: the backend's `duration` is a TOTAL target duration, not a delta. The engine must compute `duration = round(sourceDurationSeconds + addedDurationSeconds)` (fetching `sourceDurationSeconds` itself, e.g. via the analyze op) before calling. Passing `addedDurationSeconds` straight through as `duration` would be a bug, not a mapping. |
| `instruction` | `caption` | `caption` | optional, default `""`; continuation-guidance text, not a delta against an existing caption (there is no prior caption to delta against, unlike revise) |
| `seed` | `seed` | `seed` | |
| `model` (implicit) | `model` | `model_name` | default `acestep-v15-turbo` (turbo, like generate/cover, NOT base like revise/layer/autocomplete) |
| `steps` (implicit) | `num_inference_steps` | `num_inference_steps` | default 8 |

Backend safety fallback (not the normal protocol path): if the engine ever calls
`generate_continuation` with `duration<=0`, the method defaults to doubling the
source length itself. The protocol always resolves a concrete `duration` first,
so this fallback should never trigger from the Gen Protocol service; documented
so a future lane does not rely on it as a feature.

### layer -> `generate_lego`

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `contextAudioRef` | `source_audio` | `source_audio` | optional; empty string default means "no context, generate the stem standalone" |
| `instruction` | `instruction` | `instruction` | **1:1, no rename** (unlike revise, this backend method really does have an `instruction` field). Required. Examples in 02-ARCH section 5 ("bass", "sax lead") match `generate_lego`'s own docstring examples verbatim. |
| `caption` | `caption` | `caption` | optional additional description |
| `seed` | `seed` | `seed` | |
| `model` (implicit) | `model` | `model_name` | default `acestep-v15-base` |
| `steps` (implicit) | `num_inference_steps` | `num_inference_steps` | default 50 |

**Capability gap, reflected in the schema**: `generate_lego`'s RPC handler does
not read `shift`, `infer_method`, `use_adg`, `cfg_interval_start/end`,
`thinking`, `lm_top_k`, `lm_top_p`, `lm_negative_prompt`, or
`constrained_decoding` at all (compare to `generate_music`/`generate_repaint`,
which do). `layerRequest` in `gen-protocol.schemas.json` does not expose these
fields, on purpose, so the contract does not promise a knob the backend silently
ignores. Same gap applies to `generate_extract` (separate/ace-extract) and
`generate_auto_complete` (autocomplete) — see below.

### retake -> polymorphic: `generate_repaint` or `generate_music`

**Not a 1:1 mapping to one backend function.** `retakeRequest` in
`gen-protocol.schemas.json` requires `sourceTakeId` and makes
`regionStartSeconds`/`regionEndSeconds` a paired optional group:

- **Both present** (region retake): engine calls `generate_repaint` with the
  same `source_audio`/`repainting_start`/`repainting_end`/`caption` as the
  request that produced `sourceTakeId`, plus a freshly minted `seed`.
- **Both absent** (whole-song retake): engine calls `generate_music` with the
  same `caption` (and other params) as `sourceTakeId`'s original request, plus a
  freshly minted `seed`.
- **One present, one absent**: invalid; conformance tooling should reject this
  shape (checked by the `retake_region_pair_incomplete` invalid fixture).

`ace_generator.generate_variants` is **not** the retake primitive, even though
its name suggests it. Reading the code: `generate_variants(count, ...)` jitters
`bpm` by `(index - count//2) * 2` and `key` by `_shift_key(key, index)` per
variant in addition to a `base_seed + index` seed. For `count=1, index=0` those
jitters are no-ops (`_shift_key(key, 0)` returns `key` unchanged, confirmed by
reading the helper), so `generate_variants(count=1)` happens to be equivalent to
`generate_music` with a chosen seed — but `generate_variants` is what backs
`generate`'s `nVariants > 1`, a batch of N independently-seeded-and-jittered
candidates from one prompt, which is a different product concept from "reroll
this one specific take with the same prompt."

### autocomplete -> `generate_auto_complete` (flag v1.1)

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `sourceAudioRef` | `source_audio` | `source_audio` | required, must exist |
| `caption` | `caption` | `caption` | required; describes the desired full arrangement |
| `seed` | `seed` | `seed` | |
| `model` (implicit) | `model` | `model_name` | default `acestep-v15-base` |
| `steps` (implicit) | `num_inference_steps` | `num_inference_steps` | default 50 |

**Same `task_type="complete"` as extend, different method and different
duration default.** `generate_auto_complete` and `generate_continuation` both
set `GenerationParams(task_type="complete", ...)` inside `ace_generator.py`, but
they are two separate Python methods with two separate RPC handlers
(`generate_auto_complete` vs `generate_continuation`) and two different
`duration<=0` fallbacks: auto_complete matches the source length exactly (fill
gaps, don't grow it); continuation doubles the source length (grow it). Do not
collapse these into one op: they are already two ops in both the command catalog
and this protocol, correctly.

### cover -> `generate_cover` (flag v1.1)

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `referenceAudioRef` | `reference_audio` | `reference_audio` | required, must exist |
| `caption` | `caption` | `caption` | required |
| `coverStrength` | `cover_strength` | `cover_strength` | **1:1, no rename**. 0.0..1.0, default 0.5, clamped on the wire. Internally becomes ACE-Step's `audio_cover_strength`, but that rename happens inside `ace_generator.py`, not at the wire boundary this protocol targets. |
| `seed` | `seed` | `seed` | |
| `model` (implicit) | `model` | `model_name` | default `acestep-v15-turbo` (turbo, like generate/extend) |
| `steps` (implicit) | `num_inference_steps` | `num_inference_steps` | default 8 |

### separate -> `export_stems` (engine=demucs) or `generate_extract` (engine=ace-extract)

**demucs** (default):

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `sourceAudioRef` | `file_path` | `source_path` | |
| n/a (engine picks) | `output_dir` | `output_dir` | engine-managed temp/asset dir |
| `instruction` | ignored | ignored | demucs always produces all 4 stems; there is no stem-selection knob on this path |

Response: `{"result": {"stems": {"vocals":..., "drums":..., "bass":...,
"other":...}, "output_dir": ...}}`. Invocation is literally `python -m demucs -n
htdemucs -o <output_dir> <source>` via `subprocess.run` — **no progress
notifications at all** on this path (confirmed: no `progress_callback` parameter
exists on `export_stems`, unlike every `generate_*` method). A `progressEvent`
stream for `separate` with `engine=demucs` should not be expected by any UI in
v1; the job simply blocks until the terminal state.

**ace-extract**:

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `sourceAudioRef` | `source_audio` | `source_audio` | required, must exist |
| `instruction` | `instruction` | `instruction` | required; comma-separated stems to isolate, e.g. `"vocals, drums"` — this is a request for those NAMED stems, semantically different from demucs's fixed 4-way split |
| n/a | `caption` | `caption` | optional context, defaults `""` |
| n/a (implicit) | `model` | `model_name` | default `acestep-v15-base` |
| n/a (implicit) | `num_inference_steps` | `num_inference_steps` | default 50 |

This path's resulting `gen.landed.engineIdentity.model` is an ACE-Step model
name (e.g. `acestep-v15-base`), never `"htdemucs"` — the two `separate` engines
must be distinguishable in lineage, per 02-ARCH section 5 ("or engine=ace-extract
labeled generative in lineage").

### analyze -> `understand_music` (mode=full) or `analyze_audio_file` (mode=fast)

**full** (default):

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `sourceAudioRef` | `audio_path` | `audio_path` | required, must exist |
| n/a (implicit) | `lm_model` | `lm_model_path` | default `acestep-5Hz-lm-1.7B` |

Response fields map directly: `caption, lyrics, bpm, key, duration, language,
time_signature` (flat, not nested). Emits progress notifications ("analyzing"
10%, "done" 100%). Falls back internally to librosa-only bpm/key/duration if the
AI path is unavailable (model not installed, OOM, etc.), same response shape
with the AI-only fields (`caption, lyrics, language, time_signature`) empty.

**fast**:

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `sourceAudioRef` | `file_path` | (via `_extract_metadata`, `librosa.get_duration`) | required, must exist |
| `existingCaption` | `caption` | (synthetic-history seed for LLM enrichment) | optional |
| `existingTitle` | `title` | (synthetic-history seed for LLM enrichment) | optional |

Response nested under `{"result": {"parameters": {...}}}`: `bpm` (rounded to
int), `key`, `duration` (rounded to 1 decimal) always present when derivable;
`caption, lyrics, genre, style` only present when `existingCaption` or
`existingTitle` was given (triggers a synthetic-conversation pass through the
same LLM extraction used by chat). No progress notifications; synchronous;
skips model loading entirely unless the enrichment branch runs.

**Gap present in both modes, flagged as a proposal, not invented around**:
neither backend path produces `downbeats` or `loudnessLufs`. `downbeats` has no
implementation anywhere in `ace_generator.py` or `rpc_server.py` today.
`loudnessLufs` (EBU R128 / LUFS) is explicitly planned to live in the Rust
engine's `media` crate (02-ARCH section 3: "media: ... analysis, loudness"), not
in the Python backend at all. `gen-protocol.schemas.json`'s `analyzeResponse`
makes both fields nullable with a description saying so; both are `null` in
every v1 fixture. **Proposal**: either (a) a later lane implements downbeat
detection somewhere and this contract gains a concrete producer, or (b)
`downbeats` is dropped from the analyze response at the next contract revision
if it stays unowned. Not resolving this silently either way.

### finalize -> `generate_repaint` (session adaptation, not in the original 02-ARCH section 5 op list)

02-ARCH section 5's prose lists nine ops (generate, revise, extend, layer,
retake, autocomplete, cover, separate, analyze) and does not mention finalize by
name; section 4's command catalog does name `gen.finalize` ("re-render a
committed draft take at full quality and splice in place: same region, same
lineage"). This lane's session brief explicitly requires a `gen.finalize` Gen
Protocol op with "the same request shape as the revise op that produced the
draft, plus the draft take id and target quality rung," so it is included as a
tenth op here, clearly marked as such rather than silently folded into revise.

| Gen Protocol field | RPC wire param | Python param | Notes |
|---|---|---|---|
| `draftTakeId` | n/a | n/a | engine looks up the draft take's original request (source_audio/region/instruction/scope) from its lineage record |
| `targetQualityRung` | `model` + `num_inference_steps` | `model_name` + `num_inference_steps` | `draft` -> `acestep-v15-turbo`/8 steps. `standard` -> `acestep-v15-quality`/**step count not observed in any shipped call site** (open question below). `full` -> `acestep-v15-base`/50 steps. |
| `request.*` | same as revise | same as revise | identical `source_audio`/`repainting_start`/`repainting_end`/`caption` as the draft's own originating request |
| n/a (design choice) | `seed` | `seed` | **reuses the draft take's own seed**, not a fresh one — finalize is a faithful higher-quality re-render of the same creative result, not a re-roll. This is a design choice this lane is making explicitly, flagged for confirmation, not asserted as pre-existing backend behavior. |

**Open question (propose, don't invent)**: `list_models()` in `ace_generator.py`
returns three models — `["acestep-v15-turbo", "acestep-v15-quality",
"acestep-v15-base"]` — but no `generate_*` method in the current codebase
defaults to or calls out `acestep-v15-quality`'s step count. The `standard`
quality rung's step default in `qualityRung` is therefore inferred to exist
(the model name does) but its step count is not grounded in any read call site.
Proposing this be confirmed (or the `standard` rung dropped to just `draft`/
`full` until it is) at the next contract revision rather than guessing a number.

## Capabilities discovery (`gen.capabilities` / `GET /gen/capabilities`)

`ServerPool` (Swift) already tracks route health and Keychain-scoped API keys
per 02-ARCH section 1; `capabilitiesResponse` in this contract is the shape the
engine's agent-surface exposes after ServerPool merges what each configured
route reports. v1 fixture data lists `local-mlx` with the ops this backend
actually supports today (`generate, revise, extend, layer, retake, autocomplete,
cover, separate, analyze`; `finalize` reuses revise's underlying call so it is
also listed) and the three models from `list_models()`.
