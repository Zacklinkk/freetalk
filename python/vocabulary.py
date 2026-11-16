"""Local, explicit vocabulary and spelling normalization; no fuzzy substitutions."""
import re
from disfluency import LITERALS

MAX_PERSONAL_TERMS = 200
MAX_ACTIVE_TERMS = 48
TOKEN = re.compile(r'(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9_+.#/-]{1,39}')
LETTERS = re.compile(r'(?<![A-Za-z0-9_])[A-Za-z0-9](?:[ \t]+[A-Za-z0-9]){1,23}(?![A-Za-z0-9_])')
# Capital letters read out one by one: "S F T" is SFT, "L L M" is LLM. A run
# followed by a count ("A B C 三个选项") names separate options and stays.
SPELLED = re.compile(r'(?<![A-Za-z0-9_])(?:[A-Z]|[a-z](?=(?:[ \t][A-Z]){2}))(?:[ \t][A-Z]){1,7}(?![A-Za-z0-9_])')
OPTION_COUNT = re.compile(r'[ \t]*(?:[两三四五六七八九十几]|\d)+[ \t]*(?:个|种|项|类|组|档|级|部分|选项)')
# Device names the recognizer writes as a transliteration, only where the
# reading is clear: 下载到我的麦克上 is a Mac, 麦克风 is a microphone.
LOANWORDS = [(re.compile(r'(?:(?<=的)|(?<=台)|(?<=到)|(?<=在)|(?<=用))麦克(?=上(?![周次午班个月线来去台面传楼车学课])|电脑|笔记本|系统)'), 'Mac')]


def personal_terms(values):
    if not isinstance(values, list):
        return []
    result, seen = [], set()
    for value in values[:MAX_PERSONAL_TERMS]:
        if not isinstance(value, str):
            continue
        term = value.strip()
        if not term or len(term) > 64 or any(ord(c) < 32 or ord(c) == 127 for c in term):
            continue
        key = term.casefold()
        if key not in seen:
            seen.add(key)
            result.append(term)
    return result


def technical_token(term):
    return (bool(re.fullmatch(r'[A-Za-z][A-Za-z0-9]{1,23}', term)) and
            (sum(c.isupper() for c in term) >= 2 or any(c.isdigit() for c in term)))


def personal_aliases(values, terms):
    if not isinstance(values, list): return []
    result, seen = [], set()
    for row in values[:200]:
        if not isinstance(row,dict): continue
        old,new = row.get('heard'),row.get('term')
        if not isinstance(old,str) or not isinstance(new,str): continue
        if not 2 <= len(old) <= 64 or not 2 <= len(new) <= 64 or old == new or new not in terms: continue
        if any(c in old+new for c in '\r\n\t') or re.findall(r'\d+',old) != re.findall(r'\d+',new): continue
        # Punctuation and spaces belong to the transcript, not the term. A pair
        # like "插画。" -> "cha hua" would otherwise enter the ASR hotword list
        # as a literal string and never match anything.
        if any(c in old+new for c in '，。！？、；：""''「」『』（）()【】[]{}…—·,.!?;:\'"') or re.search(r'\s', old+new): continue
        stage = row.get('stage') if row.get('stage') in ('asr', 'cleanup') else 'asr'
        count = row.get('count') if isinstance(row.get('count'), int) and row.get('count') > 0 else 1
        if old not in seen: result.append({'heard':old,'term':new,'stage':stage,'count':min(count,999)}); seen.add(old)
    return result


def asr_rescue_terms(context):
    """Terms the recognizer has misheard before, most often first.

    These deserve a hotword slot even when nothing on screen mentions them:
    that is exactly the case where the recognizer needs the bias.
    """
    rows = sorted((r for r in context.get('personal_aliases', []) if r.get('stage', 'asr') == 'asr'),
                  key=lambda r: -r.get('count', 1))
    return list(dict.fromkeys(r['term'] for r in rows))


def normalize_aliases(raw, context):
    """Compatibility boundary: a past correction never authorizes replacement.

    Retain the stored pairs for inspection/undo, but use their canonical words
    only as vocabulary hints. A text-only pair has neither acoustic evidence nor
    sufficient context to overwrite a legitimate word such as get with git.
    """
    return raw,0


def spelling_context(raw, context):
    """Same-utterance canonical acronyms can resolve letter spacing, never homophones."""
    result = dict(context)
    rows = list(context.get('terms', []))
    seen = {row['term'].casefold() for row in rows}
    masked = LITERALS.sub(lambda m: ' ' * len(m[0]), raw)
    for match in TOKEN.finditer(masked):
        term = match[0].rstrip('./')
        if technical_token(term) and term.casefold() not in seen:
            rows.append({'term': term, 'source': 'utterance'})
            seen.add(term.casefold())
    result['terms'] = rows[:MAX_PERSONAL_TERMS + MAX_ACTIVE_TERMS]
    return result


def normalize_spelling(raw, context):
    """Join one maximal spelled-letter group only when its exact spelling is known."""
    known = {}
    for row in context.get('terms', []):
        term = row['term']
        if re.fullmatch(r'[A-Za-z][A-Za-z0-9]{1,23}', term) and (row.get('source') == 'personal' or technical_token(term)):
            known.setdefault(term.casefold(), term)
    spans = [(m.start(), m.end()) for m in LITERALS.finditer(raw)]
    count = 0
    def replace(match):
        nonlocal count
        if any(match.start() < b and match.end() > a for a, b in spans):
            return match[0]
        key = re.sub(r'[ \t]', '', match[0]).casefold()
        if key not in known:
            return match[0]
        count += 1
        return known[key]
    text = LETTERS.sub(replace, raw)
    spans = [(m.start(), m.end()) for m in LITERALS.finditer(text)]
    def join(match):
        nonlocal count
        letters = re.sub(r'[ \t]', '', match[0]).upper()
        # "A B C" are option labels, not an acronym; so are letters before a count.
        if any(match.start() < b and match.end() > a for a, b in spans) or OPTION_COUNT.match(text, match.end()) or letters == 'ABCDEFGH'[:len(letters)]:
            return match[0]
        # "v L M" next to Chinese is VLM; in English text "a B C" stays.
        neighbors = text[max(0, match.start() - 1):match.start()] + text[match.end():match.end() + 1]
        if match[0][0].islower() and not any('\u4e00' <= c <= '\u9fff' for c in neighbors):
            return match[0]
        count += 1
        return letters
    text = SPELLED.sub(join, text)
    text, cased = personal_casing(text, context)
    text, loans = loanwords(text)
    text, versions = normalize_known_versions(text, context)
    return text, count + cased + loans + versions


def personal_casing(raw, context):
    """Write a personal term with its own capitals: lora → LoRA, sft → SFT.

    Only terms whose capitals are not ordinary sentence case, and only next to
    Chinese text: inside an English sentence "it" or "can" stay words.
    """
    spans = [(m.start(), m.end()) for m in LITERALS.finditer(raw)]
    count = 0
    for term in context.get('personal_terms', []):
        if not re.fullmatch(r'[A-Za-z][A-Za-z0-9]{1,23}', term) or term in (term.lower(), term.capitalize()):
            continue
        if term.isupper() and len(term) < 3:
            continue
        def replace(match):
            nonlocal count
            if match[0] == term or any(match.start() < b and match.end() > a for a, b in spans):
                return match[0]
            before = raw[:match.start()].rstrip(' \t')[-1:]
            after = raw[match.end():].lstrip(' \t')[:1]
            if not any('\u4e00' <= c <= '\u9fff' or c in '，。！？；：、' for c in before + after):
                return match[0]
            count += 1
            return term
        raw = re.sub(r'(?<![A-Za-z0-9_])' + re.escape(term) + r'(?![A-Za-z0-9_])', replace, raw, flags=re.I)
    return raw, count


def loanwords(raw):
    spans = [(m.start(), m.end()) for m in LITERALS.finditer(raw)]
    count = 0
    for pattern, word in LOANWORDS:
        def replace(match):
            nonlocal count
            if any(match.start() < b and match.end() > a for a, b in spans):
                return match[0]
            count += 1
            before = raw[match.start() - 1:match.start()]
            after = raw[match.end():match.end() + 1]
            return (' ' if '\u4e00' <= before <= '\u9fff' else '') + word + (' ' if '\u4e00' <= after <= '\u9fff' else '')
        raw = pattern.sub(replace, raw)
    return raw, count


def normalize_known_versions(raw, context):
    """Render a spoken version only if that exact identifier is present in context.

    This joins literal spellings and number names, never guesses a different term.
    """
    digits = {'0':'(?:0|零|〇|zero)', '1':'(?:1|一|幺|one)', '2':'(?:2|二|two)',
              '3':'(?:3|三|three)', '4':'(?:4|四|four)', '5':'(?:5|五|five)',
              '6':'(?:6|六|six)', '7':'(?:7|七|seven)', '8':'(?:8|八|eight)', '9':'(?:9|九|nine)'}
    known = []
    for row in context.get('terms', []):
        term = row.get('term','')
        if re.fullmatch(r'[A-Za-z][A-Za-z-]{0,30}[0-9]+(?:\.[0-9]+)*',term):
            known.append(term)
            # A hyphenated model name can provide its own exact version suffix.
            if '-' in term and re.fullmatch(r'[A-Z][0-9]+(?:\.[0-9]+)*',term.rsplit('-',1)[-1]):
                known.append(term.rsplit('-',1)[-1])
    count = 0
    for term in sorted(set(known),key=len,reverse=True):
        spans = [(m.start(),m.end()) for m in LITERALS.finditer(raw)]
        pattern = r'(?<![A-Za-z0-9_])' + r'[ \t]*'.join(digits.get(c, r'(?:\.|点)' if c=='.' else r'(?:-|[ \t])?' if c=='-' else re.escape(c)) for c in term) + r'(?![A-Za-z0-9_.])'
        def replace(match):
            nonlocal count
            if any(match.start()<b and match.end()>a for a,b in spans): return match[0]
            if match[0] != term: count += 1
            return term
        raw = re.sub(pattern, replace, raw, flags=re.I)
    return raw,count


def hotwords(context):
    """Bound the ASR prompt; contextual terms rank ahead of unrelated personal words.

    The backend joins the list with ", " and appends it to the prompt, so order
    is the only signal — there is no per-term weight. Terms that actually occur
    in the visible context go first, ordered by where they first appear, then
    the rest keep their vocabulary order.
    """
    background = '\n'.join(context.get(k,'') for k in ('initial','latest','after','selected','window_title','nearby'))
    terms = list(dict.fromkeys(row['term'] for row in context.get('terms', []) if row.get('term')))

    def position(term):
        """Index of `term` in the context, or -1. Latin terms need a word boundary."""
        if term.isascii() and any(c.isalpha() for c in term):
            match = re.search(r'(?<![A-Za-z0-9_])' + re.escape(term) + r'(?![A-Za-z0-9_])', background, re.I)
            return match.start() if match else -1
        return background.casefold().find(term.casefold())

    ranked = sorted(((position(term), index, term) for index, term in enumerate(terms)))
    relevant = [term for at, _, term in ranked if at >= 0]
    rest = [term for at, _, term in ranked if at < 0]
    rescue = [term for term in asr_rescue_terms(context) if term in rest]
    rest = rescue + [term for term in rest if term not in rescue]
    return (relevant + rest)[:MAX_ACTIVE_TERMS]


def loose_sound(syllable):
    """Pinyin with the usual confusions merged: zh/z, ch/c, sh/s, ang/an, eng/en, ing/in."""
    return re.sub(r'([aei])ng$', r'\1n', re.sub(r'^([zcs])h', r'\1', syllable))


def sounding_runs(text):
    """Chinese runs of three or more characters with one loose syllable each."""
    from pypinyin import lazy_pinyin, Style
    for match in re.finditer(r'[\u4e00-\u9fff]{3,}', LITERALS.sub(' ', text)):
        sounds = lazy_pinyin(match[0], style=Style.NORMAL)
        if len(sounds) == len(match[0]):
            yield match[0], tuple(loose_sound(x) for x in sounds)


def spelling_hints(raw, context):
    """Bounded near-sound pairs from supplied text, never automatic replacements."""
    from edits import grounded_spelling
    stop=set('的了是在我你他她它这那就也都和与有个对不没无非零一二两三四五六七八九十百千万')
    known=list(dict.fromkeys(r['term'] for r in context.get('terms',[])))[:120]
    # Candidate width must follow the vocabulary: a fixed 2-4 character window
    # can never produce a 5-character term such as 星禾知识库, so longer
    # personal names were silently unhintable.
    sizes=sorted({len(term) for term in known if re.fullmatch(r'[\u4e00-\u9fff]{2,8}',term)}, reverse=True)
    def candidates(text):
        words=[]
        for match in re.finditer(r'[\u4e00-\u9fff]{2,}',LITERALS.sub(' ',text)):
            run=match[0]
            for size in sizes:
                for i in range(len(run)-size+1):
                    word=run[i:i+size]
                    if not any(c in stop for c in word) and word not in words:words.append(word)
        return words
    # Bound the scan but keep the tail reachable: sampling only the first 600
    # characters dropped any error after that point.
    heard=candidates(raw[:1200])[:200]
    pairs=[];seen=set()
    for old in heard:
        for new in known:
            key=tuple(sorted((old,new)))
            if old==new or len(old)!=len(new) or key in seen:continue
            if grounded_spelling(raw,old,new,context):
                pairs.append([old,new]);seen.add(key)
                if len(pairs)>=8:return pairs
    # Names and terms already written in the input field, the window title or
    # on screen: 林小峰 → 林晓峰, 下普比率 → 夏普比率. Two characters collide
    # too often (公司/公式, 时间/实践), so only spans of three or four.
    background = '\n'.join(context.get(k, '') for k in ('initial', 'latest', 'after', 'selected', 'window_title', 'nearby'))
    if background.strip():
        index = {}
        for run, sounds in sounding_runs(background):
            for size in (4, 3):
                for i in range(len(run) - size + 1):
                    index.setdefault(sounds[i:i + size], set()).add(run[i:i + size])
        for run, sounds in sounding_runs(raw[:1200]):
            for size in (4, 3):
                for i in range(len(run) - size + 1):
                    old = run[i:i + size]
                    if old in background:
                        continue
                    for new in sorted(index.get(sounds[i:i + size], ())):
                        key = tuple(sorted((old, new)))
                        # A longer pair already covers this one: 林小峰 covers 小峰.
                        covered = any(a.find(old) >= 0 and a.find(old) == b.find(new) for a, b in pairs)
                        if new == old or key in seen or covered or not grounded_spelling(raw, old, new, context):
                            continue
                        pairs.append([old, new]); seen.add(key)
                        if len(pairs) >= 8:
                            return pairs
    # A learned pair is context, not a rule: surface it so the model can weigh
    # it against this utterance. Without this the editor never learns that a
    # correction exists, and its own grounded spelling edit is then refused.
    for row in context.get('personal_aliases',[]):
        if row.get('stage','asr') != 'asr': continue
        heard_word, term = row.get('heard',''), row.get('term','')
        if not heard_word or not term or heard_word not in raw: continue
        if LITERALS.search(heard_word): continue
        key=tuple(sorted((heard_word,term)))
        if key in seen: continue
        pairs.append([heard_word,term]); seen.add(key)
        if len(pairs)>=8: break
    return pairs
