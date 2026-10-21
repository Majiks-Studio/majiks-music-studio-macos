# DEPRECATED: This wrapper package is superseded by the pip-installed ``acestep`` package.
# Nothing in the codebase imports from here anymore. Safe to delete after v1.5 migration.
from .handler import AceStepHandler
from .llm_inference import LLMHandler
from .inference import GenerationParams, GenerationConfig, generate_music

__all__ = ['AceStepHandler', 'LLMHandler', 'GenerationParams', 'GenerationConfig', 'generate_music']
