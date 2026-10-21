"""Repaint reality harness (lane P0-A).

Measures ACE-Step 1.5 repaint/extend/lego quality at region boundaries,
stem-scope splice viability, and honest latency. See docs/evidence/p0a-repaint.md.

Package layout:
- barmath.py   bar/beat/sample math. Standard library only.
- splice.py    equal-power crossfade splicing. numpy only.
- metrics.py   boundary and null-test metrics. numpy only.
- tempo.py     tempo/beat-grid metrics. Requires librosa (GPU box venv).
- gen_stage.py generation runner. Requires torch + acestep (ACE-Step venv).
- analyze_stage.py analysis runner. Requires librosa/soundfile + demucs CLI.
- report.py    renders markdown tables from stage outputs. Standard library only.

The math modules (barmath, splice, metrics) never import torch, librosa,
or each other, so their tests run on any machine with numpy + pytest.
"""
