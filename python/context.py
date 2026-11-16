"""Bounded, source-grounded context; native caller supplies only the selected input and opt-in visible context."""
import re
from vocabulary import personal_terms, personal_aliases

def normalize_context(data):
    """The input field (start, text before and after the caret, the selection),
    the app, window title, web domain and opt-in visible text, each bounded."""
    initial = str(data.get('initial', ''))[:500]
    latest = str(data.get('latest', ''))[-1000:]
    after = str(data.get('after', ''))[:500]
    selected = str(data.get('selected', ''))[:2000]
    app = str(data.get('app', ''))[:100]
    scene = str(data.get('scene', ''))[:40]
    title = str(data.get('window_title', ''))[:200]
    domain = str(data.get('domain', ''))[:100]
    nearby = str(data.get('nearby', ''))[:4000]
    personal = personal_terms(data.get('personal_terms', []))
    terms, seen = [], {term.casefold() for term in personal}
    # Terms seen only in the visible text are marked: like that text, they stay on this Mac.
    for text, source in (('\n'.join((initial, latest, after, selected, title)), None), (nearby, 'visible')):
        for match in re.finditer(r'(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9_+.#/-]{1,39}', text):
            term = match.group(0).rstrip('./')
            if term.casefold() not in seen:
                terms.append((term, source))
                seen.add(term.casefold())
    # Explicit personal spellings plus observed context; no fixed project word list.
    return {'initial': initial, 'latest': latest, 'after': after, 'selected': selected, 'app':app, 'scene':scene,
            'window_title':title, 'domain': domain, 'nearby':nearby,
            'personal_terms': personal,
            'layout_policy': 'paragraphs' if data.get('layout_policy') == 'paragraphs' else 'minimal',
            'personal_aliases': personal_aliases(data.get('personal_aliases', []), personal),
            'terms': [{'term': t, 'source': 'personal'} for t in personal] + [{'term': t, **({'source': s} if s else {})} for t, s in terms[:24]]}


def add_visible_text(context, text):
    """`context` with more visible text (window text recognized after recording started)."""
    text = str(text)[:4000]
    if not text.strip():
        return context
    joined = '\n'.join(x for x in (context.get('nearby', ''), text) if x)
    return normalize_context({**context, 'nearby': joined})
