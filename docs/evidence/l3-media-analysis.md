# L3 media + analysis: evidence

Crate: engine/media (standalone; coordinator joins it to the workspace at merge).
Verified by the coordinator after the lane agent completed the code but ran out of
quota before writing this doc.

## What ran
- cargo test (native default features): 29 passed / 0 failed / 2 ignored
  (decode_roundtrip, golden_tempo, gen_protocol_field_parity, real_song_sanity,
  plus unit tests). The 2 ignored are the real-app-library sanity tests that need
  local audio files present.
- cargo check --target wasm32-unknown-unknown --no-default-features: clean
  (the pure peak/tile/tempo math compiles to wasm; decode/io are native-gated).

## Surface delivered
- decode.rs: one symphonia 0.6 decode service, rubato windowed-sinc SRC, truthful
  canonical-rate stamping (44.1k pinned by test), blake3 content hash on ingest.
- tempo.rs: beat-tracked TempoMapEstimate (bpm, confidence, first_beat_offset,
  downbeats). BINDING per P0-A: generated audio drifts 1.2-2.9% off declared BPM,
  so this measured map is the bar-snap source of truth; declared BPM is only a prior.
- tiles.rs / tile_job.rs: async cancel-safe waveform peak tiles at zoom buckets,
  deterministic output.
- key.rs: chroma key estimate. loudness.rs: ebur128 integrated LUFS + true peak.
- examples/analyze.rs: CLI emitting analysis JSON for agents/tests.
- MAPPING.md: field-parity note vs the Gen Protocol analyze op.

## Reproduce
    cd engine/media && cargo test
    cargo check --target wasm32-unknown-unknown --no-default-features

## Deviations
- .cargo/config.toml (local target-dir share) was NOT committed; it was a
  machine-local build-cache optimization, redundant once media joins the workspace.
