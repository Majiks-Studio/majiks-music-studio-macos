# Majik's Music Studio: Gen Protocol cookbook

The Gen Protocol is Majik's Music Studio's single async job contract for audio
generation and editing. Every operation, from text-to-music to stem separation,
is submitted as a job, tracked by a `jobId`, and completes in a terminal state
(`done`, `failed`, or `cancelled`). A caller POSTs a typed request body (the
shape depends on which op it is invoking) and receives a `202` with a
`submitResponse` containing only a `jobId`. Progress arrives as streaming
`progressEvent` notifications for the local route or via polling
`GET /gen/jobs/{jobId}` for remote routes. The job reaches a terminal state
carrying `artifacts` (file paths and content hashes), `engineIdentity` (model,
steps, device), and optionally `latencySeconds`. The `analyze` op is an
exception: `mode=fast` and the `librosa` fallback for `mode=full` return
synchronously as an `analyzeResponse` rather than producing a job.

This cookbook shows the realistic request and result shapes for every op in the
spec, ordered as they appear in the OpenAPI paths.

## The job lifecycle (once)

Every op shares the same async lifecycle. The only difference is the request
body shape and the result details.

**Step 1: Submit**

POST to the op-specific route with a body containing the required
`requestId` (caller-supplied ULID, echoed back as the `jobId`) and the op's
typed fields.

```json
POST /gen/generate
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W4",
  "caption": "a warm jazz quartet with brushed drums and upright bass",
  "durationSeconds": 180,
  "bpm": 126,
  "key": "Db",
  "timeSig": "4",
  "nVariants": 1
}
```

Response:

```json
{
  "jobId": "01J9XQK2M5N7P8R9S0T1U2V3W4"
}
```

**Step 2: Progress (local route via RPC notifications; remote route via polling)**

The local MLX route emits `progressEvent` notifications over the existing JSON-RPC
notification channel. Remote routes use polling parity:

```json
GET /gen/jobs/01J9XQK2M5N7P8R9S0T1U2V3W4
```

```json
{
  "state": "running",
  "jobId": "01J9XQK2M5N7P8R9S0T1U2V3W4"
}
```

Progress event (notification, not a response):

```json
{
  "jobId": "01J9XQK2M5N7P8R9S0T1U2V3W4",
  "stage": "loading model",
  "percent": 25,
  "message": "Downloading checkpoint acestep-v15-turbo"
}
```

**Step 3: Terminal state**

Three possible outcomes:

Done:

```json
{
  "state": "done",
  "jobId": "01J9XQK2M5N7P8R9S0T1U2V3W4",
  "artifacts": [
    {
      "kind": "mix",
      "path": "/assets/jobs/01J9XQK2M5N7P8R9S0T1U2V3W4/mix.wav",
      "contentHash": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
    }
  ],
  "engineIdentity": {
    "model": "acestep-v15-turbo",
    "steps": 8,
    "seed": 42,
    "device": "mlx"
  },
  "latencySeconds": 12.4
}
```

Failed:

```json
{
  "state": "failed",
  "jobId": "01J9XQK2M5N7P8R9S0T1U2V3W4",
  "error": {
    "code": "OUT_OF_MEMORY",
    "message": "MPS out of memory during denoising step 64",
    "fix": "Try the turbo model with fewer steps, or free MPS memory.",
    "detail": "Requested 4.2 GB on a 16 GB MPS device with 1.1 GB free.",
    "step": "denoising"
  }
}
```

Cancelled:

```json
{
  "state": "cancelled",
  "jobId": "01J9XQK2M5N7P8R9S0T1U2V3W4"
}
```

To cancel an in-flight job:

```json
POST /gen/jobs/01J9XQK2M5N7P8R9S0T1U2V3W4/cancel
```

```json
{
  "jobId": "01J9XQK2M5N7P8R9S0T1U2V3W4"
}
```

## Ops

### generate

When to use: Create audio from a text prompt with optional lyrics and musical
parameters.

Request:

```json
POST /gen/generate
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W4",
  "caption": "a warm jazz quartet with brushed drums and upright bass",
  "lyrics": "verse 1 and chorus",
  "durationSeconds": 180,
  "bpm": 126,
  "key": "Db",
  "timeSig": "4",
  "vocalLanguage": "en",
  "seed": 42,
  "model": "acestep-v15-turbo",
  "steps": 8,
  "nVariants": 1
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `durationSeconds` is clamped to 30..600. Default: 150.
- `timeSig` defaults to `"4"`.
- `model` defaults to `acestep-v15-turbo`. `steps` defaults to 8 (turbo).
- `nVariants` (1..5, default 1) controls whether `generate_music` (single) or
  `generate_variants` (batch) is called. With `nVariants > 1`, the backend
  jitters `bpm` and `key` per variant index in addition to a seed sweep.
- If `nVariants > 1`, the done `artifacts` array contains one entry per variant.

### revise

When to use: Repaint a time region of an existing track with an instruction delta.
This is the signature Gen Protocol op.

Request:

```json
POST /gen/revise
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W5",
  "sourceAudioRef": "/assets/project1/mix.wav",
  "regionStartSeconds": 45.0,
  "regionEndSeconds": 73.5,
  "instruction": "replace the synth lead with a muted guitar",
  "scope": "drums",
  "seed": 101,
  "variants": 1
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `sourceAudioRef` is required and must reference an existing file.
- `regionStartSeconds` defaults to 0.0.
- `regionEndSeconds` defaults to -1.0 (end of track). -1 is the backend's
  "end of track" sentinel for `repainting_end`.
- `instruction` maps to the backend's `caption` parameter (the mapping doc calls
  this an "instruction -> caption delta").
- `scope` defaults to `"all-stems"`. When `scope != all-stems`, the stem-scope
  pipeline activates: the engine repaints the mix region with surrounding
  context via `generate_repaint`, then calls `export_stems` (htdemucs) on the
  repainted region, splices only the requested stem(s) into the multitrack
  result, leaves the rest byte-identical (null-preserved), and records a
  per-stem hash in the `gen.landed` entry's `assetHashes`.
- `model` defaults to `acestep-v15-base`. `steps` defaults to 50 ("honest
  latency").
- `variants > 1` is not a single backend call. The engine issues that many
  sequential `generate_repaint` calls with incrementing seeds, same
  instruction/region.
- Valid `scope` values: `"all-stems"`, `"vocals"`, `"drums"`, `"bass"`,
  `"other"`.

### extend

When to use: Continue audio from where a clip ends, growing the total duration.

Request:

```json
POST /gen/extend
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W6",
  "sourceAudioRef": "/assets/project1/verse.wav",
  "addedDurationSeconds": 30,
  "instruction": "build into a chorus with cymbal crashes",
  "seed": 77
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `sourceAudioRef` is required and must reference an existing file.
- `addedDurationSeconds` is a positive delta (exclusive minimum 0). The backend
  receives `duration = round(sourceDurationSeconds + addedDurationSeconds)`, not
  the raw delta.
- `instruction` is optional (default `""`). It is continuation-guidance text,
  not a delta against a prior caption.
- `model` defaults to `acestep-v15-turbo`. `steps` defaults to 8.

### layer

When to use: Generate a new stem that fits existing context audio (lego mode).

Request:

```json
POST /gen/layer
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W7",
  "contextAudioRef": "/assets/project1/mix.wav",
  "instruction": "bass",
  "caption": "warm fretless bass line, supporting the chord progression",
  "seed": 202
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `instruction` is required and maps 1:1 to the backend's own `instruction`
  parameter (examples: `"bass"`, `"sax lead"`).
- `contextAudioRef` is optional. Empty string (or omitted) means generate the
  stem with no reference context.
- `caption` is optional additional description.
- `model` defaults to `acestep-v15-base`. `steps` defaults to 50.
- `layerRequest` does NOT expose advanced diffusion parameters (`shift`,
  `infer_method`, `use_adg`, `cfg_interval_*`, `lm_top_k`, `lm_top_p`,
  `lm_negative_prompt`, `constrained_decoding`). These are silently not read by
  the underlying `generate_lego` RPC method.

### retake

When to use: Produce a fresh-seed variation of an existing region or whole song
using the same prompt.

Request (region retake, both region fields present):

```json
POST /gen/retake
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W8",
  "sourceTakeId": "01J9XQK2M5N7P8R9S0T1U2V3W1",
  "regionStartSeconds": 45.0,
  "regionEndSeconds": 73.5
}
```

Request (whole-song retake, both region fields absent):

```json
POST /gen/retake
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W9",
  "sourceTakeId": "01J9XQK2M5N7P8R9S0T1U2V3W1"
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `sourceTakeId` is required.
- `regionStartSeconds` and `regionEndSeconds` are a paired optional group:
  - Both present: routes to `generate_repaint` with the same region/instruction
    as the source take, plus a fresh seed.
  - Both absent: routes to `generate_music` with the same caption as the source
    take, plus a fresh seed.
  - One present, one absent: invalid. Conformance tooling rejects this shape.
- This is NOT the same as `generate` with `nVariants > 1`. The retake does not
  jitter bpm or key.

### autocomplete

When to use: Fill in missing instruments around an existing partial mix.

Request:

```json
POST /gen/autocomplete
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3XA",
  "sourceAudioRef": "/assets/project1/partial_mix.wav",
  "caption": "full arrangement with drums, bass, and pad",
  "seed": 303
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `sourceAudioRef` is required and must reference an existing file.
- `caption` is required; it describes the desired full arrangement.
- `model` defaults to `acestep-v15-base`. `steps` defaults to 50.
- `autocomplete` and `extend` both set `task_type="complete"` internally, but
  they are distinct Python entry points with different duration defaults:
  autocomplete matches the source length exactly (fill gaps, do not grow it);
  extend doubles the source length.

### cover

When to use: Produce a style-transfer cover from a reference clip.

Request:

```json
POST /gen/cover
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3XB",
  "referenceAudioRef": "/assets/reference/original_song.wav",
  "caption": "lo-fi hip-hop beat with vinyl crackle",
  "coverStrength": 0.4,
  "seed": 404
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `referenceAudioRef` is required and must reference an existing file.
- `caption` is required.
- `coverStrength` (0.0..1.0, default 0.5): 0.0 means more style transfer; 1.0
  means closer to the reference.
- `model` defaults to `acestep-v15-turbo`. `steps` defaults to 8.

### separate

When to use: Split a mix into individual stems.

Request (demucs, default):

```json
POST /gen/separate
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3XC",
  "sourceAudioRef": "/assets/project1/mix.wav"
}
```

Request (ace-extract):

```json
POST /gen/separate
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3XD",
  "sourceAudioRef": "/assets/project1/mix.wav",
  "engine": "ace-extract",
  "instruction": "vocals, drums"
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `sourceAudioRef` is required and must reference an existing file.
- `engine` defaults to `"demucs"`.
- `demucs` path: the backend runs `htdemucs` which always produces all 4 stems
  (vocals, drums, bass, other). `instruction` is ignored. No progress
  notifications are emitted on this path (a blocking `subprocess.run` call).
  The `gen.landed.engineIdentity.model` will reflect htdemucs.
- `ace-extract` path: the backend calls `generate_extract`. `instruction` is
  required and specifies comma-separated stems to isolate (e.g. `"vocals,
  drums"`). `model` defaults to `acestep-v15-base`. `steps` defaults to 50.
  The `gen.landed.engineIdentity.model` is an ACE-Step model name, never
  `"htdemucs"`.

### analyze

When to use: Extract bpm, key, duration, lyrics, and metadata from audio.

Request (full mode, default):

```json
POST /gen/analyze
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3XE",
  "sourceAudioRef": "/assets/project1/clip.wav",
  "mode": "full"
}
```

Request (fast mode, synchronous):

```json
POST /gen/analyze
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3XF",
  "sourceAudioRef": "/assets/project1/clip.wav",
  "mode": "fast",
  "existingCaption": "jazz quartet with piano",
  "existingTitle": "Morning Coffee"
}
```

Returns (fast mode, synchronous `analyzeResponse`):

```json
{
  "bpm": 118,
  "key": "Cm",
  "duration": 47.3,
  "downbeats": null,
  "loudnessLufs": null,
  "caption": "jazz quartet with piano",
  "lyrics": "",
  "language": "en",
  "timeSig": "4/4",
  "genre": "jazz",
  "style": "cool jazz"
}
```

Returns (full mode, synchronous via RPC):

```json
{
  "bpm": 118,
  "key": "Cm",
  "duration": 47.3,
  "downbeats": null,
  "loudnessLufs": null,
  "caption": "lo-fi jazz hip-hop beat with piano",
  "lyrics": "",
  "language": "en",
  "timeSig": "4/4"
}
```

Notes:

- `sourceAudioRef` is required and must reference an existing file.
- `mode` defaults to `"full"`.
- `full` mode: maps to `understand_music` with an AI-powered LLM path and a
  librosa fallback. Emits progress events ("analyzing" 10%, "done" 100%). If
  the AI path is unavailable, falls back to librosa-only with `caption`,
  `lyrics`, `language`, and `time_sig` empty.
- `fast` mode: maps to `analyze_audio_file`, signal-only, synchronous, no
  progress events. `existingCaption` and `existingTitle` are optional; if
  either is provided, the response includes `caption`, `lyrics`, `genre`, and
  `style` from LLM enrichment.
- `downbeats` and `loudnessLufs` are always `null` in v1. Neither exists in the
  Python backend yet. Both are nullable in the schema to allow future production.

### finalize

When to use: Re-render a committed draft take at full quality and splice it in
place with the same lineage.

Request:

```json
POST /gen/finalize
{
  "requestId": "01J9XQK2M5N7P8R9S0T1U2V3XG",
  "draftTakeId": "01J9XQK2M5N7P8R9S0T1U2V3W5",
  "targetQualityRung": "full",
  "request": {
    "requestId": "01J9XQK2M5N7P8R9S0T1U2V3W5",
    "sourceAudioRef": "/assets/project1/mix.wav",
    "regionStartSeconds": 45.0,
    "regionEndSeconds": 73.5,
    "instruction": "replace the synth lead with a muted guitar",
    "scope": "drums"
  }
}
```

Returns: a `submitResponse` with the echoed `jobId`, then the terminal state.

Notes:

- `draftTakeId` is required. The engine looks up the draft take's original
  request (source_audio, region, instruction, scope) from its lineage record.
- `targetQualityRung` maps to model and step count:
  - `"draft"` -> `acestep-v15-turbo`, 8 steps.
  - `"standard"` -> `acestep-v15-quality`, step count not observed in any
    shipped call site (open question per the mapping doc).
  - `"full"` -> `acestep-v15-base`, 50 steps.
- The `request` field is the same shape as `reviseRequest`: identical
  `sourceAudioRef`, `regionStartSeconds`, `regionEndSeconds`, `instruction`,
  and `scope` as the draft's originating request.
- The draft take's own seed is reused, not a fresh one, for lineage fidelity.

## Capabilities

To discover which endpoints, models, and concurrent slots are available per
engine route, call:

```json
GET /gen/capabilities
```

Response:

```json
{
  "endpoints": [
    {
      "route": "local-mlx",
      "ops": [
        "generate",
        "revise",
        "extend",
        "layer",
        "retake",
        "autocomplete",
        "cover",
        "separate",
        "analyze",
        "finalize"
      ],
      "models": [
        "acestep-v15-turbo",
        "acestep-v15-quality",
        "acestep-v15-base"
      ],
      "concurrentSlots": 1
    },
    {
      "route": "remote-ace",
      "ops": [
        "generate",
        "revise",
        "extend",
        "retake",
        "autocomplete",
        "cover"
      ],
      "models": [
        "acestep-v15-turbo",
        "acestep-v15-base"
      ],
      "concurrentSlots": 4
    }
  ]
}
```

Each endpoint object carries:

- `route`: one of `"local-mlx"`, `"remote-ace"`, `"gen-node"`, `"uc-cloud"`.
- `ops`: list of operation names supported on this route.
- `models`: list of model names available on this route.
- `concurrentSlots`: integer count of simultaneous jobs this route handles.

If a `route` field is omitted from a request body, the ServerPool selects the
route. If a `model` field is omitted, each op defaults to its own model (see the
op-specific Notes above).
