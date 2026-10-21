"""
DEPRECATED: This wrapper is superseded by the pip-installed ``acestep.handler``
(ACE-Step 1.5 package).  Nothing in the codebase imports from this module
anymore — ``ace_generator.py`` imports directly from ``acestep.handler``.
Kept only for reference; safe to delete once the v1.5 migration is fully
validated in production.
"""
import logging
from typing import Tuple, Optional
try:
    from acestep.pipeline_ace_step import ACEStepPipeline
except ImportError:
    from acestep.acestep_v15_pipeline import ACEStepPipeline

logger = logging.getLogger(__name__)


class AceStepHandler:
    """Wrapper around ACEStepPipeline that provides the expected handler interface."""

    def __init__(self):
        self.pipeline: Optional[ACEStepPipeline] = None
        self.project_root: Optional[str] = None
        self.device: str = "mps"

    def initialize_service(
        self,
        project_root: str,
        config_path: str = "acestep-v15-turbo",
        device: str = "mps"
    ) -> Tuple[str, bool]:
        """
        Initialize the ACE-Step pipeline.

        Args:
            project_root: Path to ACE-Step installation
            config_path: Model configuration name
            device: Device to use (mps, cuda, cpu)

        Returns:
            Tuple of (status_message, success_bool)
        """
        try:
            self.project_root = project_root
            self.device = device

            # Map device to device_id for pipeline
            device_id = 0
            if device == "cpu":
                device_id = -1

            # Determine dtype based on device
            dtype = "float32"  # Safe default for MPS
            if device == "cuda":
                dtype = "bfloat16"

            logger.info(f"Initializing ACEStepPipeline: root={project_root}, device={device}")

            self.pipeline = ACEStepPipeline(
                checkpoint_dir=project_root,
                device_id=device_id,
                dtype=dtype,
                torch_compile=False,  # Disable for compatibility
                cpu_offload=False,
                overlapped_decode=False
            )

            return "ACE-Step DiT model initialized successfully", True

        except Exception as e:
            logger.error(f"Failed to initialize ACE-Step: {e}")
            return str(e), False

    def generate(
        self,
        prompt: str,
        lyrics: str = "",
        audio_duration: int = 150,
        infer_step: int = 50,
        guidance_scale: float = 4.5,
        seed: int = -1,
        **kwargs
    ):
        """
        Generate audio using the pipeline.
        This is called internally by generate_music() in inference.py
        """
        if self.pipeline is None:
            raise RuntimeError("Pipeline not initialized. Call initialize_service first.")

        return self.pipeline(
            audio_duration=audio_duration,
            prompt=prompt,
            lyrics=lyrics,
            infer_step=infer_step,
            guidance_scale=guidance_scale,
            manual_seeds=[seed] if seed >= 0 else None,
            **kwargs
        )
