# ACE-Step MLX Backend Testing Guide

## What Changed

The app now uses ACE-Step 1.5's native MLX backend instead of PyTorch MPS for music generation. This should:
- Eliminate MPS memory leaks (~10GB/generation that required process restarts)
- Provide 2-3x faster DiT inference via native Metal
- Support LLM quantization (4-bit/8-bit) for lower memory usage
- Enable deterministic memory cleanup via `mx.metal.clear_cache()`

## Quick Start

The MLX backend is enabled by default. No configuration needed.

```bash
# Build the app (MLX backend is default)
./build-release.sh --skip-upload

# To force legacy MPS backend (for comparison testing):
ACE_STEP_BACKEND=mps ./build-release.sh --skip-upload
```

## Testing Checklist

### 1. Basic Generation (MLX)
- [ ] Launch app, go through Setup Wizard, download models
- [ ] Generate a track with default settings (Turbo 2B, 0.6B LM)
- [ ] Verify audio quality sounds normal (no distortion, no silence)
- [ ] Check Activity Monitor: note memory usage after generation

### 2. Memory Stability (CRITICAL)
- [ ] Generate 5 tracks consecutively WITHOUT restarting the app
- [ ] After each generation, note memory in Activity Monitor
- [ ] **Key question**: Does memory climb with each generation, or stay flat?
- [ ] If flat: the MPS memory leak is gone and process restart can be removed
- [ ] If climbing: MLX still leaks, and we keep the restart

### 3. Speed Comparison
- [ ] Generate the same track (same seed, same params) on MLX
- [ ] Set `ACE_STEP_BACKEND=mps` in environment, restart app
- [ ] Generate with same seed/params on MPS
- [ ] Compare generation time

### 4. All Generation Modes
- [ ] Text-to-music: standard generation from lyrics/description
- [ ] Cover: generate from reference audio (if models support it)
- [ ] Continuation: extend an existing track

### 5. LM Model Sizes
- [ ] 0.6B LM — should work on 16GB
- [ ] 1.7B LM — should work on 24GB+
- [ ] 4B LM — should work on 32GB+

### 6. Hardware Floor
- [ ] Test on M2 Max 64GB (dev machine) — should work great
- [ ] If possible: test on a 16GB machine — can it generate with 0.6B LM?
- [ ] If possible: test on an 8GB machine — does it work at all with MLX?

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `ACE_STEP_BACKEND` | `mlx` | `mlx` (native Metal) or `mps` (legacy PyTorch) |
| `ACESTEP_LM_BACKEND` | `mlx` | LLM backend for 5Hz model |
| `ACESTEP_MLX_VAE_FP16` | `0` | Set to `1` for float16 VAE (saves ~50% VAE memory) |
| `ACE_STEP_FORCE_CPU` | `0` | Force CPU-only (no GPU) |
| `ACE_STEP_LLM_CPU` | `0` | Run LLM on CPU, keep DiT on GPU |

## If MLX Works (No Memory Leak)

Report back and I'll:
1. Remove `restartForGeneration()` from BackendViewModel.swift
2. Remove the restart call from GenerationQueue.processLocalJobs()
3. Remove the restart call from EnhancedStudioView.swift
4. Update memory estimates based on your measurements
5. Lower the minimum RAM requirement if 8GB works

## If MLX Has Issues

Set `ACE_STEP_BACKEND=mps` to fall back to the old PyTorch path. Everything will work as before. Report what went wrong and we'll fix it.
