"""
LLMHandler wrapper - The new ACE-Step 1.5 integrates the LLM into the main pipeline.
This provides the expected interface for ace_generator.py compatibility.
"""
import logging
from typing import Tuple, Optional

logger = logging.getLogger(__name__)


class LLMHandler:
    """
    Wrapper for LLM functionality in ACE-Step 1.5.

    In the new architecture, the LLM is part of the main ACEStepPipeline.
    This class provides the expected interface while delegating to the pipeline.
    """

    def __init__(self):
        self.initialized = False
        self.checkpoint_dir: Optional[str] = None
        self.lm_model_path: Optional[str] = None
        self.device: str = "mps"

    def initialize(
        self,
        checkpoint_dir: str,
        lm_model_path: str = "acestep-5Hz-lm-1.7B",
        backend: str = "pt",
        device: str = "mps"
    ) -> Tuple[str, bool]:
        """
        Initialize the LLM handler.

        In ACE-Step 1.5, the LLM is loaded as part of the main pipeline.
        This method just records the configuration for later use.

        Args:
            checkpoint_dir: Directory containing model checkpoints
            lm_model_path: Path to the language model
            backend: Backend to use (pt for PyTorch)
            device: Device to use (mps, cuda, cpu)

        Returns:
            Tuple of (status_message, success_bool)
        """
        try:
            self.checkpoint_dir = checkpoint_dir
            self.lm_model_path = lm_model_path
            self.device = device
            self.initialized = True

            logger.info(f"LLM configuration set: model={lm_model_path}, device={device}")
            return f"LLM handler ready with {lm_model_path}", True

        except Exception as e:
            logger.error(f"Failed to initialize LLM handler: {e}")
            return str(e), False

    def get_config(self):
        """Get the current LLM configuration."""
        return {
            "checkpoint_dir": self.checkpoint_dir,
            "lm_model_path": self.lm_model_path,
            "device": self.device,
            "initialized": self.initialized
        }
