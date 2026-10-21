"""Make the repaint_harness package importable when pytest runs from repo root.

These tests need only the standard library and numpy. They must never pull
in torch, librosa, or acestep, so they run on the Mac (Python 3.14) where
torch is unavailable.
"""

import sys
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))
