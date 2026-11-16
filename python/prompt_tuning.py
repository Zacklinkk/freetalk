"""Turn accumulated user corrections into cleanup preferences, then check them.

The user's own edits after insertion are the evidence: what the recognizer
heard (raw), what cleanup inserted (cleaned) and what the user left (final).
A strong cloud model reads those cases and writes a few general preferences.
Nothing changes until the preferences are replayed through the local editor
and the user adopts them; the existing safety checks still apply afterwards.
The optimizer's prompt is prompts/prompt-tuning.txt.
"""
import json
import re

from cloud_client import CloudUnavailable, json_object

MAX_CASES = 30
MAX_ACCEPTED = 10
MAX_TEXT = 800
MAX_RULES = 10
MAX_RULE_CHARS = 80


def clean_rules(values):
    """Preferences as safe single-line rules; anything else is dropped."""
    rules = []
    for value in values if isinstance(values, list) else []:
        if not isinstance(value, str):
            continue
        # Drop a list marker ("- ", "1. ", "2、") but never a leading number in the rule itself.
        rule = re.sub(r'^(?:[-•*]|\d{1,2}[.、)])\s*', '', re.sub(r'\s+', ' ', value).strip()).strip()
        if 4 <= len(rule) <= MAX_RULE_CHARS and not any(ord(c) < 32 for c in rule) and rule not in rules:
            rules.append(rule)
    return rules[:MAX_RULES]


def bounded(text):
    text = text if isinstance(text, str) else ''
    return text if len(text) <= MAX_TEXT else text[:MAX_TEXT] + '…'


def request(cases, current_rules, preferences):
    """The user message for the optimizer: rules, current preferences and numbered cases."""
    rows = [{'case': i, 'raw': bounded(c.get('raw')), 'cleaned': bounded(c.get('inserted')), 'final': bounded(c.get('final'))}
            for i, c in enumerate(cases[:MAX_CASES])]
    return json.dumps({'current_rules': current_rules, 'current_preferences': preferences, 'cases': rows}, ensure_ascii=False)


def propose(complete, cases, current_rules, preferences, timeout=240):
    """Ask the strong model; return (rules, detail) or raise CloudUnavailable."""
    from prompt_files import source
    reply = complete([{'role': 'system', 'content': source('prompt-tuning.txt')},
                      {'role': 'user', 'content': request(cases, current_rules, preferences)}], 8000, timeout)
    try:
        value = json_object(reply)
    except ValueError:
        raise CloudUnavailable('invalid_json') from None
    rules = clean_rules(value.get('preferences'))
    detail = {k: value.get(k) for k in ('evidence', 'ignored') if isinstance(value.get(k), list)}
    return rules, detail


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, y in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (x != y))
    return row[-1]


def evaluate(edit, cases, accepted, old_rules, new_rules, progress=lambda done, total: None):
    """Replay feedback and accepted dictations under both rule sets.

    `edit(raw, rules)` returns the cleaned text. A feedback case improves when
    the new output is closer to what the user kept; an accepted dictation (the
    user did not touch it) should come out unchanged. All old-rule outputs are
    produced first, so the editor switches rules once, not once per case.
    """
    cases, accepted = cases[:MAX_CASES], accepted[:MAX_ACCEPTED]
    raws = [c['raw'] for c in cases] + list(accepted)
    total, done, outputs = 2 * len(raws), 0, {}
    for key, rules in (('old', old_rules), ('new', new_rules)):
        outputs[key] = []
        for raw in raws:
            outputs[key].append(edit(raw, rules)); done += 1; progress(done, total)
    scores = {'improved': 0, 'worse': 0, 'same': 0, 'accepted_changed': 0, 'accepted_total': len(accepted)}
    examples = []
    for i, case in enumerate(cases):
        old, new = outputs['old'][i], outputs['new'][i]
        before, after = distance(old, case['final']), distance(new, case['final'])
        key = 'improved' if after < before else 'worse' if after > before else 'same'
        scores[key] += 1
        if key != 'same' and len(examples) < 6:
            examples.append({'result': key, 'before': old[:200], 'after': new[:200], 'final': case['final'][:200]})
    # A dictation the user left alone that now comes out differently is the
    # risk of adopting: show it, so the user can judge whether it got worse.
    changed = []
    for i in range(len(cases), len(raws)):
        if outputs['old'][i] != outputs['new'][i]:
            scores['accepted_changed'] += 1
            if len(changed) < 6:
                changed.append({'result': 'accepted_changed', 'before': outputs['old'][i][:200], 'after': outputs['new'][i][:200]})
    return scores, examples + changed
