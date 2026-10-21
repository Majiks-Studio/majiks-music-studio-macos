"""Generation stage for the repaint reality harness.

Runs INSIDE the ACE-Step 1.5 venv on a CUDA box (torch + acestep required).
Never imported by the math modules or the tests.

Usage (from a directory whose parent holds repaint_harness/):
    python -m repaint_harness.gen_stage \
        --ace-root /home/muut/models/ACE-Step-1.5 \
        --out /home/muut/daw-p0a/out \
        --stages songs,matrix,probes,ladder,extend,lego

The harness mirrors the app backend (src/python/majik_backend/ace_generator.py)
parameter for parameter:
- generate:  task_type=text2music, turbo, 8 steps, guidance 4.5
- revise:    task_type=repaint, base, 50 steps, repainting_start/end seconds,
             instruction left at the GenerationParams default, normalization on
             (this is exactly what the shipped app sends)
- extend:    task_type=complete, turbo, 8 steps
- layer:     task_type=lego, base, 50 steps

Probe ops then flip one knob at a time (enable_normalization=False,
chunk_mask_mode=explicit, canonical repaint instruction from
TASK_INSTRUCTIONS) to isolate what each does to boundary and null behavior.

Every op is wall-clock timed (model load time recorded separately) and
appended to out/manifest.json as it completes.
"""

from __future__ import annotations

import argparse
import gc
import json
import os
import shutil
import sys
import time
from pathlib import Path

from repaint_harness import barmath

SAMPLE_RATE = 48000  # ACE-Step 1.5 output rate

TURBO = "acestep-v15-turbo"
BASE = "acestep-v15-base"
XL_BASE = "acestep-v15-xl-base"
LM_MODEL = "acestep-5Hz-lm-1.7B"

SONG_A_CAPTION = (
    "energetic indie rock, driving electric guitars, punchy live drums, "
    "melodic male vocals, anthemic chorus, tight rhythm section, "
    "modern rock production"
)
SONG_A_LYRICS = """[verse]
City lights are burning through the window pane
Every empty promise coming down like rain
I keep running faster just to stay in place
Another siren singing down the interstate

[chorus]
We are the wire, we are the spark
Kicking out the shadows, swinging at the dark
Hold your colors higher till the morning breaks
We are the fire that no one takes

[verse]
Paper crowns and gasoline, the whole street glows
Every borrowed heartbeat wants a second show
I found my direction when the map ran out
Turn the amplifiers up and drown the doubt

[chorus]
We are the wire, we are the spark
Kicking out the shadows, swinging at the dark
Hold your colors higher till the morning breaks
We are the fire that no one takes

[bridge]
If the night comes crashing, let it come
We were built from static, built to run

[chorus]
We are the wire, we are the spark
Kicking out the shadows, swinging at the dark
"""

SONG_B_CAPTION = (
    "smooth neo-soul groove, warm Rhodes electric piano, soulful female "
    "vocals, deep pocket bass, laid back drums, lush backing harmonies, "
    "warm analog production"
)
SONG_B_LYRICS = """[verse]
Sunday morning honey dripping off the vine
Coffee going cold because your hands found mine
Every little minute got a golden glow
We got nowhere else that we need to go

[chorus]
Stay right here, let the record spin
Velvet on the speakers, let the warmth come in
Stay right here, we got time to burn
Love is just a lesson that we are slow to learn

[verse]
Window full of amber, dust is hanging still
You hum a little melody, you always will
If the phone keeps ringing, let it ring all day
Nothing in this world gonna pull me away

[chorus]
Stay right here, let the record spin
Velvet on the speakers, let the warmth come in
Stay right here, we got time to burn
Love is just a lesson that we are slow to learn
"""

SONGS = {
    "A": {
        "caption": SONG_A_CAPTION,
        "lyrics": SONG_A_LYRICS,
        "bpm": 120,
        "key": "E minor",
        "duration": 112.0,
        "seed": 101,
        "region_bars": (17, 24),  # 32.0 s .. 48.0 s at 120 bpm 4/4
    },
    "B": {
        "caption": SONG_B_CAPTION,
        "lyrics": SONG_B_LYRICS,
        "bpm": 96,
        "key": "F major",
        "duration": 110.0,
        "seed": 202,
        "region_bars": (13, 20),  # 30.0 s .. 50.0 s at 96 bpm 4/4
    },
}

# Revise instruction variants: the caption the region is regenerated with.
INSTRUCTION_VARIANTS_A = {
    "retake": SONG_A_CAPTION,
    "halftime": SONG_A_CAPTION + ", half-time drums, darker brooding mood, heavy sparse groove",
    "solo": SONG_A_CAPTION + ", soaring electric guitar solo lead line",
}
INSTRUCTION_VARIANTS_B = {
    "lift": SONG_B_CAPTION + ", uplifting gospel choir harmonies, brighter energy",
}
MATRIX_SEEDS = [11, 22, 33]
REPAINT_STEPS = 50
LADDER_SPECS = [  # (model, steps) beyond the 50-step matrix twins
    (BASE, 10),
    (BASE, 20),
    (XL_BASE, 10),
    (XL_BASE, 20),
    (TURBO, 8),
]


def now() -> float:
    return time.perf_counter()


class GenRunner:
    def __init__(self, ace_root: str, out_dir: str, device: str = "cuda") -> None:
        self.ace_root = str(Path(ace_root).expanduser().resolve())
        self.out = Path(out_dir).expanduser().resolve()
        self.device = device
        self.wav_dir = self.out / "wav"
        self.raw_dir = self.out / "raw"
        self.wav_dir.mkdir(parents=True, exist_ok=True)
        self.raw_dir.mkdir(parents=True, exist_ok=True)
        self.manifest_path = self.out / "manifest.json"
        self.manifest = self._load_manifest()
        self.dit = None
        self.dit_model = None
        self.llm = None
        self.last_dit_load_s = None
        self.llm_load_s = None

        sys.path.insert(0, self.ace_root)
        os.chdir(self.ace_root)

    # ----- manifest -----

    def _load_manifest(self) -> dict:
        if self.manifest_path.exists():
            with open(self.manifest_path) as fh:
                return json.load(fh)
        return {
            "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "ace_root": str(self.ace_root),
            "sample_rate": SAMPLE_RATE,
            "songs": {},
            "ops": [],
        }

    def _flush_manifest(self) -> None:
        tmp = self.manifest_path.with_suffix(".tmp")
        with open(tmp, "w") as fh:
            json.dump(self.manifest, fh, indent=2, default=str)
        tmp.replace(self.manifest_path)

    def has_op(self, op_id: str) -> bool:
        return any(o["id"] == op_id and o.get("status") == "ok" for o in self.manifest["ops"])

    # ----- model management -----

    def load_llm(self) -> None:
        if self.llm is not None:
            return
        from acestep.llm_inference import LLMHandler

        print(f"[gen] loading LM {LM_MODEL} (backend=pt)...", flush=True)
        t0 = now()
        llm = LLMHandler()
        status, ok = llm.initialize(
            checkpoint_dir=str(Path(self.ace_root) / "checkpoints"),
            lm_model_path=LM_MODEL,
            backend="pt",
            device=self.device,
        )
        self.llm_load_s = now() - t0
        if not ok:
            raise RuntimeError(f"LM init failed: {status}")
        self.llm = llm
        print(f"[gen] LM ready in {self.llm_load_s:.1f}s: {status}", flush=True)

    def set_dit(self, model_name: str) -> None:
        if self.dit_model == model_name:
            self.last_dit_load_s = None
            return
        if self.dit is not None:
            print(f"[gen] releasing DiT {self.dit_model}", flush=True)
            self.dit = None
            gc.collect()
            try:
                import torch

                torch.cuda.empty_cache()
            except Exception:
                pass
        from acestep.handler import AceStepHandler

        print(f"[gen] loading DiT {model_name}...", flush=True)
        t0 = now()
        dit = AceStepHandler()
        status, ok = dit.initialize_service(
            project_root=self.ace_root,
            config_path=model_name,
            device=self.device,
            use_flash_attention=False,
            compile_model=False,
        )
        self.last_dit_load_s = now() - t0
        if not ok:
            raise RuntimeError(f"DiT init failed for {model_name}: {status}")
        self.dit = dit
        self.dit_model = model_name
        print(f"[gen] DiT {model_name} ready in {self.last_dit_load_s:.1f}s", flush=True)

    # ----- op execution -----

    def run_op(self, op_id: str, stage: str, model_name: str, params_kwargs: dict,
               seed: int, notes: str = "") -> dict:
        """Execute one generation op and record it in the manifest."""
        if self.has_op(op_id):
            print(f"[gen] skip {op_id} (already in manifest)", flush=True)
            return next(o for o in self.manifest["ops"] if o["id"] == op_id)

        from acestep.inference import GenerationConfig, GenerationParams, generate_music

        self.load_llm()
        self.set_dit(model_name)
        dit_load_s = self.last_dit_load_s

        params = GenerationParams(seed=seed, **params_kwargs)
        config = GenerationConfig(
            batch_size=1,
            use_random_seed=False,
            seeds=[seed],
            audio_format="wav32",
        )

        save_dir = self.raw_dir / op_id
        save_dir.mkdir(parents=True, exist_ok=True)

        print(f"[gen] {op_id}: task={params.task_type} model={model_name} "
              f"steps={params.inference_steps} seed={seed}", flush=True)
        record = {
            "id": op_id,
            "stage": stage,
            "task_type": params.task_type,
            "model": model_name,
            "steps": params.inference_steps,
            "seed": seed,
            "notes": notes,
            "dit_load_s": dit_load_s,
            "params_sent": {
                k: v for k, v in params_kwargs.items()
                if k not in ("lyrics",)  # keep manifest readable
            },
        }
        t0 = now()
        try:
            result = generate_music(self.dit, self.llm, params, config,
                                    save_dir=str(save_dir))
            wall = now() - t0
            if not result.success or not result.audios:
                raise RuntimeError(f"generation failed: {result.error}")
            audio = result.audios[0]
            src_path = audio.get("path", "")
            if not src_path or not Path(src_path).exists():
                raise RuntimeError("no audio file in result")
            artifact = self.wav_dir / f"{op_id}.wav"
            shutil.copy2(src_path, artifact)
            record.update(
                status="ok",
                wall_s=round(wall, 2),
                artifact=str(artifact),
                sample_rate=audio.get("sample_rate", SAMPLE_RATE),
                result_params=audio.get("params", {}),
                status_message=str(result.status_message)[:500],
            )
            print(f"[gen] {op_id} done in {wall:.1f}s -> {artifact}", flush=True)
        except Exception as exc:  # record and continue
            record.update(status="failed", wall_s=round(now() - t0, 2), error=str(exc))
            print(f"[gen] {op_id} FAILED: {exc}", flush=True)
        self.manifest["ops"].append(record)
        self._flush_manifest()
        return record


def repaint_kwargs(song: dict, caption: str, src_audio: str, steps: int,
                   start_s: float, end_s: float, **overrides) -> dict:
    """Repaint parameters exactly as the app backend sends them."""
    kw = dict(
        task_type="repaint",
        caption=caption,
        lyrics=song["lyrics"],
        instrumental=False,
        src_audio=src_audio,
        repainting_start=start_s,
        repainting_end=end_s,
        bpm=song["bpm"],
        keyscale=song["key"],
        timesignature="4",
        vocal_language="en",
        duration=song["duration"],
        inference_steps=steps,
        guidance_scale=4.5,
        shift=3.0,
        infer_method="ode",
        use_adg=False,
        cfg_interval_start=0.0,
        cfg_interval_end=1.0,
        thinking=True,
        lm_temperature=0.9,
        lm_cfg_scale=2.5,
        lm_top_k=0,
        lm_top_p=0.9,
        lm_negative_prompt="NO USER INPUT",
        use_cot_metas=True,
        use_cot_caption=True,
        use_cot_language=True,
        use_constrained_decoding=True,
    )
    kw.update(overrides)
    return kw


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--ace-root", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="cuda")
    ap.add_argument("--stages", default="songs,matrix,probes,ladder,extend,lego")
    args = ap.parse_args()
    stages = set(args.stages.split(","))

    runner = GenRunner(args.ace_root, args.out, args.device)

    regions = {}
    for name, song in SONGS.items():
        start_bar, end_bar = song["region_bars"]
        start_s, end_s = barmath.region_seconds(start_bar, end_bar, song["bpm"])
        regions[name] = (start_s, end_s)
        runner.manifest["songs"][name] = {
            "caption": song["caption"],
            "bpm": song["bpm"],
            "key": song["key"],
            "duration": song["duration"],
            "seed": song["seed"],
            "region_bars": list(song["region_bars"]),
            "region_seconds": [start_s, end_s],
            "artifact": str(runner.wav_dir / f"song_{name}.wav"),
        }
    runner._flush_manifest()

    def song_path(name: str) -> str:
        return str(runner.wav_dir / f"song_{name}.wav")

    # ---- songs (turbo, app generate defaults) ----
    if "songs" in stages:
        for name, song in SONGS.items():
            runner.run_op(
                f"song_{name}", "songs", TURBO,
                dict(
                    task_type="text2music",
                    caption=song["caption"],
                    lyrics=song["lyrics"],
                    instrumental=False,
                    bpm=song["bpm"],
                    keyscale=song["key"],
                    timesignature="4",
                    vocal_language="en",
                    duration=song["duration"],
                    inference_steps=8,
                    guidance_scale=4.5,
                    shift=3.0,
                    infer_method="ode",
                    thinking=True,
                    lm_temperature=0.9,
                    lm_cfg_scale=2.5,
                    lm_top_k=0,
                    lm_top_p=0.9,
                    lm_negative_prompt="NO USER INPUT",
                    use_cot_metas=True,
                    use_cot_caption=True,
                    use_cot_language=True,
                    use_constrained_decoding=True,
                ),
                seed=song["seed"],
                notes="test material, app text2music defaults",
            )

    songs_ok = all(
        runner.has_op(f"song_{n}") for n in SONGS
    )
    if not songs_ok and (stages - {"songs"}):
        print("[gen] songs missing or failed; cannot run dependent stages", flush=True)
        return 1

    a = SONGS["A"]
    b = SONGS["B"]
    a_start, a_end = regions["A"]
    b_start, b_end = regions["B"]

    # ---- repaint matrix (base then xl to minimize DiT swaps) ----
    if "matrix" in stages:
        for model, tag in ((BASE, "base50"), (XL_BASE, "xl50")):
            for variant, caption in INSTRUCTION_VARIANTS_A.items():
                for seed in MATRIX_SEEDS:
                    runner.run_op(
                        f"A_rp_{variant}_s{seed}_{tag}", "matrix", model,
                        repaint_kwargs(a, caption, song_path("A"), REPAINT_STEPS,
                                       a_start, a_end),
                        seed=seed,
                        notes=f"app repaint defaults, instruction variant {variant}",
                    )
            if model == BASE:
                for variant, caption in INSTRUCTION_VARIANTS_B.items():
                    for seed in MATRIX_SEEDS:
                        runner.run_op(
                            f"B_rp_{variant}_s{seed}_{tag}", "matrix", model,
                            repaint_kwargs(b, caption, song_path("B"), REPAINT_STEPS,
                                           b_start, b_end),
                            seed=seed,
                            notes=f"app repaint defaults, instruction variant {variant}",
                        )

    # ---- probes: one knob at a time off the halftime/seed-11/base twin ----
    if "probes" in stages:
        caption = INSTRUCTION_VARIANTS_A["halftime"]
        canonical = "Repaint the mask area based on the given conditions:"
        probes = {
            "norm_off": dict(enable_normalization=False),
            "mask_explicit": dict(chunk_mask_mode="explicit"),
            "instr_canonical": dict(instruction=canonical),
            "combo": dict(enable_normalization=False, chunk_mask_mode="explicit",
                          instruction=canonical),
        }
        for probe_id, overrides in probes.items():
            runner.run_op(
                f"A_probe_{probe_id}_s11_base50", "probes", BASE,
                repaint_kwargs(a, caption, song_path("A"), REPAINT_STEPS,
                               a_start, a_end, **overrides),
                seed=11,
                notes=f"probe {probe_id}: {overrides}",
            )

    # ---- steps ladder (matrix twins provide the 50-step rungs) ----
    if "ladder" in stages:
        caption = INSTRUCTION_VARIANTS_A["halftime"]
        for model, steps in LADDER_SPECS:
            tag = {TURBO: "turbo", BASE: "base", XL_BASE: "xl"}[model]
            runner.run_op(
                f"A_ladder_{tag}{steps}_s11", "ladder", model,
                repaint_kwargs(a, caption, song_path("A"), steps, a_start, a_end),
                seed=11,
                notes="steps ladder rung",
            )

    # ---- region-trimmed repaint (draft-path latency + quality probe) ----
    if "trimmed" in stages:
        import soundfile as sf_mod

        caption = INSTRUCTION_VARIANTS_A["halftime"]
        bar_s = barmath.seconds_per_bar(a["bpm"])
        clip_lo = a_start - bar_s
        clip_hi = a_end + bar_s
        clip_path = runner.wav_dir / "A_trimmed_src.wav"
        if not clip_path.exists():
            data, sr = sf_mod.read(song_path("A"), dtype="float32", always_2d=True)
            lo = barmath.seconds_to_sample(clip_lo, sr)
            hi = barmath.seconds_to_sample(clip_hi, sr)
            sf_mod.write(str(clip_path), data[lo:hi], sr, subtype="FLOAT")
        clip_song = dict(a)
        clip_song["duration"] = clip_hi - clip_lo
        for model, steps, tag in ((BASE, REPAINT_STEPS, "base50"), (TURBO, 8, "turbo8")):
            runner.run_op(
                f"A_trim_halftime_s11_{tag}", "trimmed", model,
                repaint_kwargs(clip_song, caption, str(clip_path), steps,
                               bar_s, bar_s + (a_end - a_start)),
                seed=11,
                notes=f"region-trimmed source clip [{clip_lo:.0f},{clip_hi:.0f}]s of song A; "
                      f"repaint bounds are clip-relative; full-song region "
                      f"[{a_start:.0f},{a_end:.0f}]s",
            )

    # ---- extend (+16 bars, app continuation defaults: turbo 8) ----
    if "extend" in stages:
        add_s = barmath.region_duration_seconds(1, 16, a["bpm"])
        runner.run_op(
            "A_extend_16bars", "extend", TURBO,
            dict(
                task_type="complete",
                caption=a["caption"],
                lyrics=a["lyrics"],
                instrumental=False,
                src_audio=song_path("A"),
                bpm=a["bpm"],
                keyscale=a["key"],
                timesignature="4",
                vocal_language="en",
                duration=a["duration"] + add_s,
                inference_steps=8,
                guidance_scale=4.5,
                shift=3.0,
                infer_method="ode",
                thinking=True,
                lm_temperature=0.9,
                lm_cfg_scale=2.5,
                lm_top_k=0,
                lm_top_p=0.9,
                lm_negative_prompt="NO USER INPUT",
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=True,
            ),
            seed=77,
            notes=f"extend by 16 bars ({add_s:.0f}s), app complete defaults",
        )

    # ---- lego layer (base 50, canonical lego instruction) ----
    if "lego" in stages:
        runner.run_op(
            "A_lego_bass", "lego", BASE,
            dict(
                task_type="lego",
                caption="warm analog synth bass line, deep and round, locking with the drum groove",
                lyrics="",
                instrumental=True,
                src_audio=song_path("A"),
                instruction="Generate the BASS track based on the audio context:",
                bpm=a["bpm"],
                keyscale=a["key"],
                timesignature="4",
                vocal_language="unknown",
                duration=a["duration"],
                inference_steps=REPAINT_STEPS,
                guidance_scale=4.5,
                thinking=True,
                lm_temperature=0.9,
                lm_cfg_scale=2.5,
                lm_top_k=0,
                lm_top_p=0.9,
                lm_negative_prompt="NO USER INPUT",
                use_cot_metas=True,
                use_cot_caption=True,
                use_cot_language=True,
                use_constrained_decoding=True,
            ),
            seed=88,
            notes="lego layer smoke: warm analog bass, canonical lego instruction "
                  "(note: the app sends the bare instrument word instead)",
        )

    n_ok = sum(1 for o in runner.manifest["ops"] if o.get("status") == "ok")
    n_fail = sum(1 for o in runner.manifest["ops"] if o.get("status") == "failed")
    print(f"[gen] complete: {n_ok} ok, {n_fail} failed -> {runner.manifest_path}",
          flush=True)
    return 0 if n_fail == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
