"""Analysis stage for the repaint reality harness.

Runs on the GPU box in a venv that has numpy, soundfile, librosa, scipy,
and the demucs CLI (torch). Consumes the gen stage manifest, computes
boundary/null/tempo metrics, runs the stem-scope pipeline, and assembles
the audition set.

Usage:
    python -m repaint_harness.analyze_stage \
        --manifest /home/muut/daw-p0a/out/manifest.json \
        --out /home/muut/daw-p0a/out \
        --demucs-models htdemucs_ft,htdemucs

Outputs:
    out/analysis.json      all measured numbers
    out/audition/*.wav     named listening files (48 kHz, 24-bit PCM)
    out/audition/index.json  file -> what to listen for
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

from repaint_harness import barmath, metrics, splice, tempo

FADE_SET_MS = [0, 5, 10, 20, 50]
AUDITION_FADE_MS = 20
STEMS = ["vocals", "drums", "bass", "other"]
SCOPED = ["drums", "other"]
DEMUCS_SR = 44100


def load_wav(path: str) -> Tuple[np.ndarray, int]:
    data, sr = sf.read(path, dtype="float64", always_2d=True)
    return data, sr


def save_wav(path: Path, data: np.ndarray, sr: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    peak = float(np.max(np.abs(data))) if data.size else 0.0
    if peak > 1.0:  # protect PCM export; note the gain in the index entry
        data = data / peak * 0.999
    sf.write(str(path), data, sr, subtype="PCM_24")


def fade_samples(ms: float, sr: int) -> int:
    return int(round(ms * 1e-3 * sr))


class Analyzer:
    def __init__(self, manifest_path: str, out_dir: str, demucs_models: List[str],
                 demucs_python: Optional[str] = None) -> None:
        self.out = Path(out_dir).expanduser().resolve()
        with open(manifest_path) as fh:
            self.manifest = json.load(fh)
        self.sr = int(self.manifest.get("sample_rate", 48000))
        self.demucs_models = demucs_models
        self.demucs_python = demucs_python or sys.executable
        self.audition_dir = self.out / "audition"
        self.audition_dir.mkdir(parents=True, exist_ok=True)
        self.sep_dir = self.out / "separated"
        self.sep_dir.mkdir(parents=True, exist_ok=True)
        self.analysis: Dict = {
            "songs": {},
            "repaints": {},
            "selection": {},
            "stem_scope": {},
            "extend": {},
            "lego": {},
            "demucs": {"timings": []},
            "audition": [],
        }
        self._audio_cache: Dict[str, Tuple[np.ndarray, int]] = {}

    # ---------- helpers ----------

    def audio(self, path: str) -> Tuple[np.ndarray, int]:
        if path not in self._audio_cache:
            self._audio_cache[path] = load_wav(path)
        return self._audio_cache[path]

    def ops(self, stage: Optional[str] = None, status: str = "ok") -> List[dict]:
        out = []
        for op in self.manifest["ops"]:
            if status and op.get("status") != status:
                continue
            if stage and op.get("stage") != stage:
                continue
            out.append(op)
        return out

    def op_by_id(self, op_id: str) -> Optional[dict]:
        for op in self.manifest["ops"]:
            if op["id"] == op_id:
                return op
        return None

    def song_for_op(self, op: dict) -> Tuple[str, dict]:
        if op["id"].startswith("song_"):
            song_id = op["id"].split("_")[1]
        else:
            song_id = op["id"][0]
        return song_id, self.manifest["songs"][song_id]

    def add_audition(self, filename: str, data: np.ndarray, sr: int, desc: str) -> None:
        save_wav(self.audition_dir / filename, data, sr)
        self.analysis["audition"].append({"file": filename, "desc": desc})
        print(f"[an] audition: {filename}", flush=True)

    def flush(self) -> None:
        tmp = self.out / "analysis.tmp"
        with open(tmp, "w") as fh:
            json.dump(self.analysis, fh, indent=2, default=str)
        tmp.replace(self.out / "analysis.json")

    # ---------- song baselines ----------

    def analyze_songs(self) -> None:
        for name, song in self.manifest["songs"].items():
            data, sr = self.audio(song["artifact"])
            mono = metrics.to_mono(data)
            offset = tempo.estimate_grid_offset_seconds(mono, sr, song["bpm"])
            grid = tempo.beat_grid_metrics(mono, sr, song["bpm"],
                                           grid_offset_seconds=offset)
            s_s, e_s = song["region_seconds"]
            s = barmath.seconds_to_sample(s_s, sr)
            e = barmath.seconds_to_sample(e_s, sr)
            baseline = {
                "start": metrics.boundary_metrics(data, s, sr, exclude=[(s, e)]),
                "end": metrics.boundary_metrics(data, e, sr, exclude=[(s, e)]),
            }
            self.analysis["songs"][name] = {
                "duration_s": data.shape[0] / sr,
                "sample_rate": sr,
                "declared_bpm": song["bpm"],
                "measured_tempo_bpm": grid["tempo_bpm"],
                "grid_offset_s": offset,
                "grid_phase_error_ms": grid["grid_phase_error_ms"],
                "peak_db": metrics.peak_db(data),
                "rms_db": metrics.rms_db(data),
                "region_seconds": [s_s, e_s],
                "region_samples": [s, e],
                "baseline_boundary": baseline,
            }
            print(f"[an] song {name}: measured tempo "
                  f"{grid['tempo_bpm']:.1f} bpm (declared {song['bpm']}), "
                  f"grid offset {offset*1000:.0f} ms", flush=True)
        self.flush()

    # ---------- repaint ops ----------

    def analyze_repaints(self) -> None:
        repaint_ops = [op for op in self.ops()
                       if op.get("task_type") == "repaint"]
        for op in repaint_ops:
            song_id, song = self.song_for_op(op)
            original, sr = self.audio(song["artifact"])
            result, rsr = self.audio(op["artifact"])
            assert rsr == sr, f"sample rate mismatch in {op['id']}"

            s_s = op["params_sent"]["repainting_start"]
            e_s = op["params_sent"]["repainting_end"]
            s = barmath.seconds_to_sample(s_s, sr)
            e = barmath.seconds_to_sample(e_s, sr)

            if op["stage"] == "trimmed":
                # The op repainted a short clip; s/e above are clip-relative.
                # Null and raw-boundary metrics run against the clip, then the
                # repainted region is spliced back into the FULL song at the
                # song's region (same length by construction).
                clip, _ = self.audio(op["params_sent"]["src_audio"])
                full_s, full_e = song["region_samples"] if "region_samples" in song \
                    else self.analysis["songs"][song_id]["region_samples"]
                entry = self._analyze_one_repaint(
                    op, song_id, song, clip, result, sr, s, e,
                    splice_target=(original, full_s, full_e))
            else:
                entry = self._analyze_one_repaint(
                    op, song_id, song, original, result, sr, s, e)
            self.analysis["repaints"][op["id"]] = entry
            print(f"[an] repaint {op['id']}: raw null strict "
                  f"{entry['raw_null']['strict']['residual_rms_db']:.1f} dB, "
                  f"score {entry.get('score', float('nan')):.2f}", flush=True)
        self.flush()

    def _analyze_one_repaint(self, op, song_id, song, original, result, sr, s, e,
                             splice_target=None):
        """original here is whatever the op repainted (full song or clip);
        splice_target=(full_song, full_s, full_e) redirects the splice set
        into the full song for region-trimmed ops."""
        n = min(original.shape[0], result.shape[0])
        length_delta = result.shape[0] - original.shape[0]
        entry: Dict = {
            "song": song_id,
            "model": op["model"],
            "steps": op["steps"],
            "seed": op["seed"],
            "stage": op["stage"],
            "wall_s": op.get("wall_s"),
            "region_samples": [s, e],
            "length_delta_samples": length_delta,
        }

        entry["raw_null"] = {
            "strict": metrics.null_residual(original, result, exclude=[(s, e)]),
            "guard250ms": metrics.null_residual(
                original, result, exclude=[(s, e)],
                guard_samples=fade_samples(250, sr)),
        }
        if s - sr // 2 > 0 and e + sr // 2 < n:
            entry["raw_boundary"] = {
                "start": metrics.boundary_metrics(result[:n], s, sr, exclude=[(s, e)]),
                "end": metrics.boundary_metrics(result[:n], e, sr, exclude=[(s, e)]),
            }

        splice_into, sp_s, sp_e = (
            splice_target if splice_target is not None else (original, s, e))
        if abs(length_delta) <= sr // 10 and e <= result.shape[0]:
            region = splice.extract_region(result, s, e)
            if region.shape[0] != sp_e - sp_s:
                entry["splices"] = None
                entry["splice_skipped_reason"] = "region length mismatch vs target"
            else:
                entry["splices"] = {}
                for ms in FADE_SET_MS:
                    spliced = splice.splice_region(
                        splice_into, region, sp_s, sp_e, fade_samples(ms, sr))
                    entry["splices"][str(ms)] = {
                        "start": metrics.boundary_metrics(
                            spliced, sp_s, sr, exclude=[(sp_s, sp_e)]),
                        "end": metrics.boundary_metrics(
                            spliced, sp_e, sr, exclude=[(sp_s, sp_e)]),
                    }
        else:
            entry["splices"] = None
            entry["splice_skipped_reason"] = (
                f"length delta {length_delta} samples too large")

        offset = self.analysis["songs"][song_id]["grid_offset_s"]
        mono_res = metrics.to_mono(result)
        mono_orig = metrics.to_mono(original)
        entry["tempo"] = {
            "original_region": tempo.beat_grid_metrics(
                mono_orig, sr, song["bpm"], region=(s, e),
                grid_offset_seconds=offset),
            "repaint_region": tempo.beat_grid_metrics(
                mono_res, sr, song["bpm"], region=(s, e),
                grid_offset_seconds=offset),
        }

        if entry.get("splices"):
            sp20 = entry["splices"]["20"]
            entry["score"] = max(sp20["start"]["flux_zscore"],
                                 sp20["end"]["flux_zscore"]) + \
                max(sp20["start"]["click_ratio"],
                    sp20["end"]["click_ratio"]) / 10.0
        return entry

    def select_takes(self) -> Tuple[str, str]:
        scored = {oid: r for oid, r in self.analysis["repaints"].items()
                  if r["stage"] == "matrix" and r["song"] == "A" and "score" in r}
        best = min(scored, key=lambda k: scored[k]["score"])
        worst = max(scored, key=lambda k: scored[k]["score"])
        self.analysis["selection"] = {"best": best, "worst": worst}
        print(f"[an] best={best} worst={worst}", flush=True)
        self.flush()
        return best, worst

    # ---------- demucs ----------

    def run_demucs(self, wav_path: Path, model: str, tag: str) -> Optional[Dict[str, str]]:
        out_root = self.sep_dir / tag
        stem_dir = out_root / model / wav_path.stem
        if not all((stem_dir / f"{s}.wav").exists() for s in STEMS):
            print(f"[an] demucs {model} on {wav_path.name}...", flush=True)
            t0 = time.perf_counter()
            method = "cli"
            ok = self._demucs_cli(wav_path, model, out_root)
            if not ok:
                # The CLI needs torchaudio I/O, which is broken in some venvs
                # (torchcodec shared-library load failure). The API path does
                # the same math with soundfile I/O.
                method = "api"
                t0 = time.perf_counter()  # do not bill the failed CLI attempt
                ok = self._demucs_api(wav_path, model, stem_dir)
            if not ok:
                return None
            wall = time.perf_counter() - t0
            dur = sf.info(str(wav_path)).duration
            self.analysis["demucs"]["timings"].append(
                {"model": model, "input": wav_path.name, "method": method,
                 "input_duration_s": round(dur, 2), "wall_s": round(wall, 2)})
            print(f"[an] demucs {model} {wav_path.name}: {wall:.1f}s "
                  f"({method}) for {dur:.1f}s audio", flush=True)
        return {s: str(stem_dir / f"{s}.wav") for s in STEMS}

    def _demucs_cli(self, wav_path: Path, model: str, out_root: Path) -> bool:
        cmd = [self.demucs_python, "-m", "demucs", "-n", model, "--float32",
               "-d", "cuda", "-o", str(out_root), str(wav_path)]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            print(f"[an] demucs CLI failed ({model}): {proc.stderr[-300:]}",
                  flush=True)
            return False
        return True

    def _demucs_api(self, wav_path: Path, model_name: str, stem_dir: Path) -> bool:
        """Same separation math as `python -m demucs`, but with soundfile I/O
        (mirrors demucs.separate normalization exactly)."""
        try:
            import torch
            from demucs.apply import apply_model
            from demucs.pretrained import get_model
        except Exception as exc:
            print(f"[an] demucs api import failed: {exc}", flush=True)
            return False
        if not hasattr(self, "_demucs_cache"):
            self._demucs_cache = {}
        model = self._demucs_cache.get(model_name)
        try:
            if model is None:
                model = get_model(model_name)
                model.eval()
                self._demucs_cache[model_name] = model
            data, sr = load_wav(str(wav_path))
            if data.shape[1] == 1:
                data = np.repeat(data, 2, axis=1)
            if sr != model.samplerate:
                data = resample_poly(data, model.samplerate, sr, axis=0)
            wav = torch.from_numpy(np.ascontiguousarray(data.T).astype(np.float32))
            ref = wav.mean(0)
            mean, std = ref.mean(), ref.std()
            wav_n = (wav - mean) / (std + 1e-8)
            with torch.no_grad():
                sources = apply_model(model, wav_n[None], device="cuda",
                                      shifts=0, split=True, overlap=0.25,
                                      progress=False)[0]
            sources = sources * (std + 1e-8) + mean
            stem_dir.mkdir(parents=True, exist_ok=True)
            for name, src in zip(model.sources, sources):
                sf.write(str(stem_dir / f"{name}.wav"),
                         src.cpu().numpy().T, model.samplerate, subtype="FLOAT")
            return True
        except Exception as exc:
            print(f"[an] demucs api failed ({model_name}): {exc}", flush=True)
            return False

    def load_stems_48k(self, stem_paths: Dict[str, str], target_len: int) -> Dict[str, np.ndarray]:
        stems = {}
        for name, p in stem_paths.items():
            data, sr = load_wav(p)
            if sr != self.sr:
                data = resample_poly(data, self.sr, sr, axis=0)
            if data.shape[0] < target_len:
                pad = np.zeros((target_len - data.shape[0], data.shape[1]))
                data = np.concatenate([data, pad], axis=0)
            stems[name] = data[:target_len]
        return stems

    def stem_scope(self, take_id: str) -> None:
        """The product rule: repaint mix region, re-separate the new region,
        splice ONLY drums+other stems over the original stems, render."""
        op = self.op_by_id(take_id)
        song_id, song = self.song_for_op(op)
        original, sr = self.audio(song["artifact"])
        result, _ = self.audio(op["artifact"])
        s_s = op["params_sent"]["repainting_start"]
        e_s = op["params_sent"]["repainting_end"]
        s = barmath.seconds_to_sample(s_s, sr)
        e = barmath.seconds_to_sample(e_s, sr)
        bar_s = barmath.seconds_per_bar(song["bpm"])
        ctx = barmath.seconds_to_sample(bar_s, sr)  # 1 bar of context each side

        report: Dict = {"take": take_id, "scoped": SCOPED,
                        "context_bars_each_side": 1}

        # Choose the first demucs model that works (htdemucs_ft preferred).
        model_used = None
        orig_stem_paths = None
        for model in self.demucs_models:
            orig_stem_paths = self.run_demucs(Path(song["artifact"]), model,
                                              tag="orig_full")
            if orig_stem_paths:
                model_used = model
                break
        if not orig_stem_paths:
            report["error"] = "demucs failed for all models"
            self.analysis["stem_scope"] = report
            self.flush()
            return
        report["demucs_model"] = model_used

        # Separate the repainted region with one bar of context each side.
        seg_lo = max(0, s - ctx)
        seg_hi = min(result.shape[0], e + ctx)
        ctx = s - seg_lo  # actual left context after clamping
        seg = result[seg_lo:seg_hi]
        seg_path = self.sep_dir / f"{take_id}_region_ctx.wav"
        sf.write(str(seg_path), seg, sr, subtype="FLOAT")
        seg_stem_paths = self.run_demucs(seg_path, model_used, tag="region_seg")
        if not seg_stem_paths:
            report["error"] = "demucs failed on region segment"
            self.analysis["stem_scope"] = report
            self.flush()
            return

        # Timing comparison for the second model, if available (latency table).
        for other in self.demucs_models:
            if other != model_used:
                self.run_demucs(seg_path, other, tag="region_seg_alt")

        n = original.shape[0]
        orig_stems = self.load_stems_48k(orig_stem_paths, n)

        # Demucs reconstruction sanity: sum of stems vs the input mix.
        recon = sum(orig_stems.values())
        report["separation_reconstruction"] = metrics.null_residual(
            original, recon, exclude=[])
        seg_stems = self.load_stems_48k(seg_stem_paths, seg.shape[0])
        region_stems = {name: st[ctx : ctx + (e - s)] for name, st in seg_stems.items()}

        fade = fade_samples(AUDITION_FADE_MS, sr)
        mix, stems_out = splice.stem_recombine(
            orig_stems, region_stems, SCOPED, s, e, fade)

        report["boundary"] = {
            "start": metrics.boundary_metrics(mix, s, sr, exclude=[(s, e)]),
            "end": metrics.boundary_metrics(mix, e, sr, exclude=[(s, e)]),
        }
        # Outside the region the recombined mix should match the sum of the
        # original stems exactly (null-preserve of the pipeline).
        report["null_vs_original_stem_sum"] = metrics.null_residual(
            recon, mix, exclude=[(s, e)])
        # And vs the actual original mix: includes separation+resample error.
        report["null_vs_original_mix"] = metrics.null_residual(
            original, mix, exclude=[(s, e)])

        offset = self.analysis["songs"][song_id]["grid_offset_s"]
        report["tempo_region"] = tempo.beat_grid_metrics(
            metrics.to_mono(mix), sr, song["bpm"], region=(s, e),
            grid_offset_seconds=offset)

        self.analysis["stem_scope"] = report
        sb, eb = song["region_bars"]
        self.add_audition(
            f"A_stemscope_drums-other_bars{sb}-{eb}_{take_id}.wav", mix, sr,
            "Stem-scope pipeline: repainted DRUMS+OTHER spliced over original "
            "stems in the region; VOCALS+BASS stay original. Listen for drum "
            "seam at region edges and groove lock against the original bass.")
        self.flush()

    # ---------- extend and lego ----------

    def analyze_extend(self) -> None:
        ops = self.ops(stage="extend")
        if not ops:
            return
        op = ops[0]
        song_id, song = self.song_for_op(op)
        original, sr = self.audio(song["artifact"])
        result, _ = self.audio(op["artifact"])
        n0 = original.shape[0]
        entry: Dict = {"id": op["id"], "wall_s": op.get("wall_s"),
                       "original_s": n0 / sr, "result_s": result.shape[0] / sr}
        if result.shape[0] > n0:
            entry["null_over_original_span"] = metrics.null_residual(
                original, result[:n0], exclude=[])
            entry["join_boundary"] = metrics.boundary_metrics(
                result, n0, sr, exclude=[(n0, result.shape[0])])
            offset = self.analysis["songs"][song_id]["grid_offset_s"]
            entry["tempo_extension"] = tempo.beat_grid_metrics(
                metrics.to_mono(result), sr, song["bpm"],
                region=(n0, result.shape[0]), grid_offset_seconds=offset)
        self.analysis["extend"] = entry
        self.add_audition(
            f"A_extend_16bars.wav", result, sr,
            "Extend op (task complete, turbo 8): original 112 s plus 16 new "
            "bars. Listen at 1:52 for the join and whether the extension "
            "keeps tempo, key, and energy.")
        self.flush()

    def analyze_lego(self) -> None:
        ops = self.ops(stage="lego")
        if not ops:
            return
        op = ops[0]
        song_id, song = self.song_for_op(op)
        original, sr = self.audio(song["artifact"])
        layer, lsr = self.audio(op["artifact"])
        entry: Dict = {"id": op["id"], "wall_s": op.get("wall_s"),
                       "layer_s": layer.shape[0] / lsr,
                       "layer_channels": layer.shape[1],
                       "layer_rms_db": metrics.rms_db(layer)}
        offset = self.analysis["songs"][song_id]["grid_offset_s"]
        entry["tempo_layer"] = tempo.beat_grid_metrics(
            metrics.to_mono(layer), lsr, song["bpm"], grid_offset_seconds=offset)
        self.analysis["lego"] = entry

        n = min(original.shape[0], layer.shape[0])
        mix = original[:n] * 0.85 + layer[:n] * 0.85
        self.add_audition(
            "A_lego_bass_layer_solo.wav", layer, lsr,
            "Lego op output alone: the generated warm analog bass layer. "
            "Listen for note choices and groove lock.")
        self.add_audition(
            "A_lego_bass_layer_mix.wav", mix, sr,
            "Lego layer mixed under the original song (both at -1.4 dB). "
            "Listen for key/tempo agreement and phase against the original bass.")
        self.flush()

    # ---------- audition assembly ----------

    def assemble_audition(self, best: str, worst: str) -> None:
        for name, song in self.manifest["songs"].items():
            data, sr = self.audio(song["artifact"])
            sb, eb = song["region_bars"]
            self.add_audition(
                f"{name}_original.wav", data, sr,
                f"Source song {name} (turbo, 8 steps, seed {song['seed']}). "
                f"The revised region is bars {sb}-{eb} = "
                f"{song['region_seconds'][0]:.0f}-{song['region_seconds'][1]:.0f} s.")

        def write_splice(op_id: str, fade_ms: float, label: str, desc: str) -> None:
            op = self.op_by_id(op_id)
            song_id, song = self.song_for_op(op)
            original, sr = self.audio(song["artifact"])
            result, _ = self.audio(op["artifact"])
            s = barmath.seconds_to_sample(op["params_sent"]["repainting_start"], sr)
            e = barmath.seconds_to_sample(op["params_sent"]["repainting_end"], sr)
            region = splice.extract_region(result, s, e)
            if op["stage"] == "trimmed":
                s, e = self.analysis["songs"][song_id]["region_samples"]
            out = splice.splice_region(original, region, s, e,
                                       fade_samples(fade_ms, sr))
            self.add_audition(label, out, sr, desc)

        a_song = self.manifest["songs"]["A"]
        sb, eb = a_song["region_bars"]
        rgn = f"bars{sb}-{eb}"
        s0, e0 = a_song["region_seconds"]
        when = f"Region {s0:.0f}-{e0:.0f} s."

        write_splice(best, 20, f"A_revise_BEST_{rgn}_{best}_fade20ms.wav",
                     f"Best matrix take by boundary metrics ({best}), spliced "
                     f"with 20 ms equal-power fades. {when}")
        write_splice(worst, 20, f"A_revise_WORST_{rgn}_{worst}_fade20ms.wav",
                     f"Worst matrix take by boundary metrics ({worst}), same "
                     f"20 ms splice. {when}")
        write_splice(best, 0, f"A_revise_BEST_{rgn}_{best}_hardcut0ms.wav",
                     f"Same take as BEST but hard cut, no crossfade. Compare "
                     f"seams at {s0:.0f} s and {e0:.0f} s.")
        write_splice(best, 50, f"A_revise_BEST_{rgn}_{best}_fade50ms.wav",
                     f"Same take as BEST with 50 ms fades. Is 20 ms vs 50 ms "
                     f"audible at the seams?")

        b_matrix = [oid for oid, r in self.analysis["repaints"].items()
                    if r["song"] == "B" and r["stage"] == "matrix" and "score" in r]
        if b_matrix:
            b_best = min(b_matrix, key=lambda k: self.analysis["repaints"][k]["score"])
            b_song = self.manifest["songs"]["B"]
            bs0, be0 = b_song["region_seconds"]
            write_splice(b_best, 20,
                         f"B_revise_{b_best}_fade20ms.wav",
                         f"Cross-genre check (neo-soul): {b_best} spliced at "
                         f"20 ms. Region {bs0:.0f}-{be0:.0f} s.")

        ladder_ids = [op["id"] for op in self.ops(stage="ladder")]
        ladder_ids += [f"A_rp_halftime_s11_base50", f"A_rp_halftime_s11_xl50"]
        for lid in ladder_ids:
            op = self.op_by_id(lid)
            if not op or op.get("status") != "ok":
                continue
            wall = op.get("wall_s") or float("nan")
            write_splice(lid, 20,
                         f"A_ladder_{op['model'].replace('acestep-v15-', '')}"
                         f"_{op['steps']}steps_fade20ms.wav",
                         f"Steps ladder rung: {op['model']} at {op['steps']} "
                         f"steps ({wall:.0f} s wall on the 3090), same seed 11, "
                         f"same halftime instruction, 20 ms splice. {when}")

        for op in self.ops(stage="trimmed"):
            wall = op.get("wall_s") or float("nan")
            write_splice(op["id"], 20,
                         f"A_trimmed-context_{op['model'].replace('acestep-v15-', '')}"
                         f"_{op['steps']}steps_fade20ms.wav",
                         f"Region-trimmed draft path: repaint ran on a 20 s clip "
                         f"(region + 1 bar context) instead of the whole song "
                         f"({wall:.0f} s wall), spliced back into the full song at "
                         f"20 ms. Compare against the full-context ladder rungs: "
                         f"does the lost context hurt? {when}")

        index = {e["file"]: e["desc"] for e in self.analysis["audition"]}
        with open(self.audition_dir / "index.json", "w") as fh:
            json.dump(index, fh, indent=2)
        self.flush()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--demucs-models", default="htdemucs_ft,htdemucs")
    ap.add_argument("--demucs-python", default=None)
    ap.add_argument("--skip-demucs", action="store_true")
    args = ap.parse_args()

    an = Analyzer(args.manifest, args.out, args.demucs_models.split(","),
                  args.demucs_python)
    an.analyze_songs()
    an.analyze_repaints()
    best, worst = an.select_takes()
    an.assemble_audition(best, worst)
    if not args.skip_demucs:
        an.stem_scope(best)
    an.analyze_extend()
    an.analyze_lego()
    an.flush()
    print(f"[an] done -> {an.out / 'analysis.json'}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
