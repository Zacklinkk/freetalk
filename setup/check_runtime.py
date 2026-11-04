"""Check the known inference API before reusing a local Python environment."""
from importlib.metadata import version

REQUIRED = {'mlx': '0.32.4', 'mlx-lm': '0.32.2', 'mlx-audio': '0.6.3',
            'numpy': '2.4.6', 'transformers': '5.22.0', 'pypinyin': '0.55.0'}
for package, expected in REQUIRED.items():
    if version(package) != expected:
        raise SystemExit(f'{package} requires {expected}')
from mlx_audio.stt.utils import load_model
from mlx_lm import load
from pypinyin import lazy_pinyin
print('Runtime ready')
