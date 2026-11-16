"""Prompt files: the built-in copy in prompts/, or the user's edited copy.

Settings → 专业配置 → 整理提示词 saves edits to <support>/prompts/<name>. An
edited copy that is empty, unreadable or (for examples) not a list of
alternating user/assistant turns is ignored, so a bad edit falls back to the
built-in prompt instead of breaking dictation.
"""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EDITABLE = ('edit-rules.txt', 'edit-plan.txt', 'edit-plan-examples.json', 'restart-plan.txt',
            'restart-plan-examples.json', 'filler-selection.txt', 'prompt-tuning.txt')
# The directory holding edited copies; the worker sets it from config['supportPath'].
overrides = None


def builtin(name):
    return (ROOT / 'prompts' / name).read_text()


def valid_turns(text):
    try:
        value = json.loads(text)
    except ValueError:
        return False
    return (isinstance(value, list) and len(value) % 2 == 0 and
            all(isinstance(m, dict) and set(m) == {'role', 'content'} and isinstance(m['content'], str)
                and m['role'] == ('user' if i % 2 == 0 else 'assistant') for i, m in enumerate(value)))


def edited(name):
    """The user's usable copy of prompts/<name>, or None."""
    if not overrides or name not in EDITABLE:
        return None
    try:
        text = (Path(overrides) / name).read_text()
    except (OSError, UnicodeDecodeError):
        return None
    if not text.strip() or (name.endswith('.json') and not valid_turns(text)):
        return None
    return text


def source(name):
    text = edited(name)
    return builtin(name) if text is None else text


def expand(name):
    """prompts/<name> with shared fragments expanded (`{{edit-rules}}` → edit-rules.txt).

    The edit and restart prompts share their repair/edit/layout rules; keeping
    them in one file stops the two copies drifting apart. Only known fragments
    expand; any other {{...}} an edit introduces stays as typed.
    """
    text = source(name)
    for marker in set(re.findall(r'\{\{([a-z-]+)\}\}', text)):
        if marker + '.txt' in EDITABLE:
            text = text.replace('{{' + marker + '}}', source(marker + '.txt').removesuffix('\n'))
    return text


def examples(name):
    return json.loads(source(name))
