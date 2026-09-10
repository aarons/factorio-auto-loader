#!/usr/bin/env python3
"""Check both runners' executable selection without launching Factorio."""
import importlib.util
from pathlib import Path
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
STANDALONE = '/Applications/factorio.app/Contents/MacOS/factorio'
PATH_COPY = '/tmp/path-factorio'
EXPLICIT = '/tmp/explicit-factorio'

for relative in ['tests/run_factorio.py', 'benchmarks/run.py']:
    spec = importlib.util.spec_from_file_location('runner', REPO/relative)
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
    for explicit, available, expected in [
        (None, {STANDALONE, PATH_COPY}, STANDALONE),
        (None, {PATH_COPY}, PATH_COPY),
        (EXPLICIT, {STANDALONE, PATH_COPY, EXPLICIT}, EXPLICIT),
        (EXPLICIT, {STANDALONE, PATH_COPY}, None),
        (None, set(), None),
    ]:
        with patch.object(runner.shutil, 'which', return_value=PATH_COPY), patch.object(
                Path, 'is_file', lambda p: str(p) in available):
            result = runner.find_factorio(explicit)
        assert result == (Path(expected).resolve() if expected else None), (relative, explicit, result)
    print(f'{relative}: standalone preference, PATH fallback, explicit override and missing install passed')
