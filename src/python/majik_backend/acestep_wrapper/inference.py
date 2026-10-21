"""
Inference wrapper - provides GenerationParams, GenerationConfig, and generate_music
for compatibility with ace_generator.py
"""
import os
import logging
from dataclasses import dataclass
from typing import Any, Dict, List, Optional
from pathlib import Path

logger = logging.getLogger(__name__)


@dataclass
class GenerationParams:
    """Parameters for music generation."""
    task_type: str = "text2music"
    caption: str = ""
    lyrics: str = ""
    instrumental: bool = True
    bpm: Optional[int] = None
    keyscale: Optional[str] = None
    duration: int = 150
    inference_steps: int = 50
    guidance_scale: float = 4.5
    seed: int = -1
    lm_temperature: float = 0.9
    lm_cfg_scale: float = 2.5
    thinking: bool = True
    use_cot_metas: bool = True
    use_cot_caption: bool = True


@dataclass
class GenerationConfig:
    """Configuration for generation."""
    batch_size: int = 1
    use_random_seed: bool = True
    audio_format: str = "wav"


@dataclass
class GenerationResult:
    """Result of music generation."""
    success: bool
    audios: List[Dict[str, Any]]
    error: Optional[str] = None


def generate_music(
    dit_handler,
    llm_handler,
    params: GenerationParams,
    config: GenerationConfig,
    save_dir: str = "./output"
) -> GenerationResult:
    """
    Generate music using ACE-Step.

    Args:
        dit_handler: The AceStepHandler with initialized pipeline
        llm_handler: The LLMHandler (used for configuration)
        params: Generation parameters
        config: Generation configuration
        save_dir: Directory to save output files

    Returns:
        GenerationResult with success status and audio info
    """
    try:
        if dit_handler.pipeline is None:
            return GenerationResult(
                success=False,
                audios=[],
                error="Pipeline not initialized"
            )

        # Ensure save directory exists
        os.makedirs(save_dir, exist_ok=True)

        # Build prompt with optional BPM and key
        prompt = params.caption
        if params.bpm:
            prompt = f"BPM: {params.bpm}. {prompt}"
        if params.keyscale:
            prompt = f"Key: {params.keyscale}. {prompt}"

        # Determine seed
        seed = params.seed
        if seed < 0 and config.use_random_seed:
            import random
            seed = random.randint(0, 1_000_000)

        logger.info(f"Generating music: prompt='{prompt[:100]}...', duration={params.duration}s, seed={seed}")

        # Generate using pipeline
        # Let the pipeline use its own defaults for scheduler_type ("euler")
        # and cfg_type ("apg" = Adaptive Projected Guidance, higher quality).
        result = dit_handler.pipeline(
            audio_duration=params.duration,
            prompt=prompt,
            lyrics=params.lyrics if not params.instrumental else "",
            infer_step=params.inference_steps,
            guidance_scale=params.guidance_scale,
            manual_seeds=[seed] if seed >= 0 else None,
            save_path=save_dir,
        )

        # Process result - pipeline returns file paths
        if isinstance(result, (list, tuple)) and len(result) > 0:
            audio_path = result[0] if isinstance(result[0], str) else str(result[0])
        elif isinstance(result, str):
            audio_path = result
        else:
            # Look for generated file in save_dir
            wav_files = list(Path(save_dir).glob("*.wav"))
            if wav_files:
                audio_path = str(sorted(wav_files)[-1])  # Get most recent
            else:
                return GenerationResult(
                    success=False,
                    audios=[],
                    error="No audio file generated"
                )

        # Build audio info
        import librosa
        try:
            duration = librosa.get_duration(path=audio_path)
        except Exception:
            duration = params.duration

        audio_info = {
            "path": audio_path,
            "sample_rate": 44100,  # ACE-Step default
            "duration": duration,
            "params": {
                "seed": seed,
                "bpm": params.bpm,
                "keyscale": params.keyscale,
                "caption": params.caption,
            }
        }

        return GenerationResult(
            success=True,
            audios=[audio_info],
            error=None
        )

    except Exception as e:
        logger.error(f"Generation failed: {e}", exc_info=True)
        return GenerationResult(
            success=False,
            audios=[],
            error=str(e)
        )
