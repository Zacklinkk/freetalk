"""The tone the user chose for a kind of app (Settings → 按应用调整语气).

自然 changes nothing. 正式 drops the chatty particle that ends a clause
(好的呀， → 好的，; 好啦 → 好了) and ends the text with a full stop. 口语 keeps
particles, as cleanup does in a chat, and drops the full stop that ends a short
one-sentence message. Neither preset rewrites words, so the model never sees it.
"""
import re

CHATTY = '呀哈呗嘞哦啦咯'
# 哎呀, 哇哦, 嘻哈 are words of their own, not a particle after a clause.
INTERJECTION = '哎唉哇嘻噢喔哦啊嗨'
SHORT = 40


def keeps_particles(context):
    """Particles are the message's tone: in a chat, or when the user chose 口语."""
    context = context or {}
    return context.get('scene') == 'conversation' or context.get('tone') == 'casual'


def apply(text, context):
    """Apply the chosen tone to cleaned text. Returns (text, count)."""
    tone = (context or {}).get('tone')
    if tone not in ('formal', 'casual') or not text.strip():
        return text, 0
    from edits import protected_span
    from disfluency import LITERALS
    count = 0
    # A particle the user put back after cleanup removed it stays (style_learning keep).
    kept = set((context or {}).get('keep_words') or ())
    last_line = text.rstrip().rsplit('\n', 1)[-1]
    listed = bool(re.match(r'\s*\d+\. ', last_line))
    if tone == 'formal':
        def particle(match):
            nonlocal count
            if match[0] in kept or protected_span(text, match.start(), match.end()):
                return match[0]
            count += 1
            # 啦 is 了 + 啊: 好啦 → 好了, but 好了啦 → 好了.
            return '了' if match[0] == '啦' and text[match.start() - 1] != '了' else ''
        # After a clause of two characters or more: 得嘞 and 是哦 are whole answers.
        text = re.sub(r'(?<=[一-鿿]{2})(?<![' + CHATTY + INTERJECTION + r'])[' + CHATTY + r'](?![' + CHATTY + r'])(?=[，,。！!；;]|\s*$)',
                      particle, text)
        end = text.rstrip()
        # A link or code at the very end would take the mark as part of it.
        if end and not listed and not any(m.end() == len(end) for m in LITERALS.finditer(end)) and (
                re.match(r'[一-鿿]', end[-1]) or end[-1].isascii() and end[-1].isalnum()):
            mark = '？' if end[-1] == '吗' else '。' if re.search(r'[一-鿿]', last_line) else '.'
            text = end + mark + text[len(end):]
            count += 1
    elif tone == 'casual':
        end = text.rstrip()
        # One sentence only: 好的。我马上过来 would end two ways.
        if len(end) <= SHORT and not re.search(r'[。！？!?\n]', end[:-1]) and re.search(r'[^.。][。]$|[A-Za-z][.]$', end):
            text = end[:-1] + text[len(end):]
            count += 1
    return text, count
