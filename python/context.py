"""Bounded, source-grounded context; native caller supplies only the selected input and opt-in visible context."""
import re
from vocabulary import personal_terms, personal_aliases

def normalize_context(data):
    initial = str(data.get('initial', ''))[:500]
    latest = str(data.get('latest', ''))[-1000:]
    app = str(data.get('app', ''))[:100]
    scene = str(data.get('scene', ''))[:40]
    title = str(data.get('window_title', ''))[:200]
    nearby = str(data.get('nearby', ''))[:1800]
    personal = personal_terms(data.get('personal_terms', []))
    terms, seen = [], {term.casefold() for term in personal}
    for match in re.finditer(r'(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9_+.#/-]{1,39}', initial + '\n' + latest + '\n' + title + '\n' + nearby):
        term = match.group(0).rstrip('./')
        if term.casefold() not in seen:
            terms.append(term)
            seen.add(term.casefold())
    # Explicit personal spellings plus observed context; no fixed project word list.
    return {'initial': initial, 'latest': latest, 'app':app, 'scene':scene, 'window_title':title, 'nearby':nearby,
            'personal_terms': personal,
            'layout_policy': 'paragraphs' if data.get('layout_policy') == 'paragraphs' else 'minimal',
            'personal_aliases': personal_aliases(data.get('personal_aliases', []), personal),
            'terms': [{'term': t, 'source': 'personal'} for t in personal] + [{'term': t} for t in terms[:24]]}
