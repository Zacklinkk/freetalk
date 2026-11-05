"""Cheap, source-preserving triage. No model call or paraphrase scoring service."""
import difflib
import re

# These patterns identify a repair cue, not permission to delete earlier content.
CUE = r'(?:不对|不是|我是说|(?:刚才|前面|之前)?[\u4e00-\u9fff]{0,8}说错了|更正一下|纠正一下|改口|改成|改为|准确地说|应该改为)'
START_CUE = re.compile(r'^(?:[\s，,。.!！?？、]*(?:呃+|嗯+|啊|哦|不对|我是说|(?:刚才|前面|之前)?[\u4e00-\u9fff]{0,8}说错了|更正一下|纠正一下|改口|改成|改为|应该是|应该改为|准确地说|而是))+[\s，,。.!！?？、]*')
EN_CUE = re.compile(r'^(?:\s*[,.;!?]?\s*(?:uh|um|no|sorry|actually|I mean|make that|scratch that)\b)+[\s,.;:]*', re.I)
RESTART_HEAD = re.compile(r'^[\s，,。]*(?:(?:哎|唉|呃+|嗯+)[，,\s]*)*(?:算了(?:吧)?|(?:我)?(?:重新说|重说)(?:一遍|一下)?|(?:把)?(?:刚才这句|刚才那句|上一句|前面那句|这句|这一句|刚才这段|上一段|这段)(?:话)?(?:不要了|删掉|作废|不算了?))(?:[，,。\s]*(?:我)?(?:重新说|重说)(?:一遍|一下)?)?[，,。\s]*')
LITERALS = re.compile(r'`[^`]*`|https?://[^\s，。]+|“[^”]*”|「[^」]*」|『[^』]*』|"[^"\n]*"')
# ASR punctuation is not a reliable boundary: "八份文件不对，改成九份".
JOINED_CUE = re.compile(r'不对(?=[\s，,。]*(?:不对|改成|改为|我是说|更正|纠正))')
EMPHASIS = re.compile(r'必须|一定|强调|重点|非常|真的|千万|重申|反复|再次|两次|多次|重要')

def mask_literals(text):
    return LITERALS.sub(lambda m: ' ' * len(m[0]), text)

def correction_signal(text):
    text = mask_literals(text)
    # A discussion/example of a correction is not a spoken correction itself.
    return bool(JOINED_CUE.search(text) or re.search(r'(?:^|[，,。.!！?？]\s*)(?:呃+[，,\s]*)?(?:不对|我是说|(?:刚才|前面|之前)[\u4e00-\u9fff]{0,8}说错了|更正一下|纠正一下|改口|改成|改为|准确地说)', text) or
                re.search(r'\b(?:I mean|make that|scratch that|actually\s*,?\s*no)\b', text, re.I))

def adjacent_repetitions(text):
    """Literal restart candidates, not permission to delete them.

    Require a pause and a repeated prefix that continues into a longer clause.
    Complete repeated statements, emphasis and numeric/distributive expressions
    are deliberately left to the speaker. The editor still selects each edit.
    """
    masked = mask_literals(text)
    for match in re.finditer(r'(?P<word>[\u4e00-\u9fff]{2,12})(?:[，,]\s*(?P=word))+(?=[\u4e00-\u9fffA-Za-z])', masked):
        start = max(masked.rfind(p, 0, match.start()) for p in '。！？!?；;\n') + 1
        end = re.search(r'[。！？!?；;\n]', masked[match.end():])
        end = match.end() + end.start() if end else len(masked)
        if EMPHASIS.search(masked[start:end]) or re.search(r'[零〇一二两三四五六七八九十百千万亿]+(?:个|条|份|组|项|页|本|张|台|人|元|遍|次|点|秒|分|小时|天|年|月)', match['word']):
            continue
        yield match

def strip_repair_cue(text):
    match = START_CUE.match(text) or EN_CUE.match(text)
    if not match: return None
    return text[match.end():].strip(' \t\r\n，,。.!！?？;；')

def unresolved_correction(text):
    # "改成九份" can itself be a perfectly complete instruction. A warning
    # needs an explicit self-correction marker left in the final text.
    return bool(re.search(r'(?:^|[，,。！？!?]\s*)(?:不对|我是说|(?:刚才|前面|之前)?[\u4e00-\u9fff]{0,8}说错了|更正一下|纠正一下|改口)', mask_literals(text)))

def inspect(text):
    """Return routing reasons only. Similarity never authorizes a deletion."""
    masked = mask_literals(text)
    reasons = []
    if correction_signal(masked): reasons.append('self_correction')
    if any(adjacent_repetitions(masked)): reasons.append('adjacent_restart')
    if any(RESTART_HEAD.match(s) for s in re.split(r'[。！？!?；;\n]',masked)):
        reasons.append('spoken_restart')
    clauses = [re.sub(r'\W','',s) for s in re.split(r'[，,。.!！?？;；\n]', masked)]
    clauses = [s for s in clauses if len(s) >= 6]
    for a,b in zip(clauses,clauses[1:]):
        if min(len(a),len(b))/max(len(a),len(b)) >= .7 and difflib.SequenceMatcher(a=a,b=b,autojunk=False).ratio() >= .76:
            reasons.append('possible_repeat');break
    # Ambiguous connectives require context. They are never a deletion blacklist.
    if re.search(r'(?:[，,]\s*)(?:那个|就是|怎么说呢|you know|like)(?:[，,]\s*)',masked,re.I):
        reasons.append('possible_filler')
    if re.search(r'嗯|呃|啊|呀|对呀|对啊|(?:^|[，,。])对[，,。]|这个|那个|就是|然后',masked) and len(re.sub(r'\W','',masked)) >= 5:
        reasons.append('contextual_filler_review')
    # A word threshold must not silently bypass a multi-sentence spoken paragraph.
    if len(masked) >= 50 or (len(masked) >= 32 and len(re.findall(r'[。！？!?]',masked)) >= 2):
        reasons.append('dictation_review')
    return reasons
