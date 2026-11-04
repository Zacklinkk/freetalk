"""Source-addressed changes. The model proposes; this module owns the text."""
import difflib
import re
from functools import lru_cache
from disfluency import LITERALS, START_CUE, EN_CUE, RESTART_HEAD, correction_signal, strip_repair_cue

def core(text):
    return re.sub(r'[\W_]', '', text).lower()

def split_units(raw):
    spans=[(m.start(),m.end()) for m in LITERALS.finditer(raw)]
    def outside(pos):return not any(a<=pos<b for a,b in spans)
    cuts={0,len(raw)}
    for m in re.finditer(r'[。！？；!?;]',raw):
        if not outside(m.start()):continue
        end=m.end()
        while end<len(raw) and raw[end] in '”’」』':end+=1
        cuts.add(end)
    markers=[m.start() for m in re.finditer(r'(?:第[一二三四五六七八九十0-9]+[，,、]|首先[，,、]|其次[，,、]|一是|二是|三是)',raw) if outside(m.start()) and (m.start()==0 or raw[m.start()-1] in '：:，,。；;\n ')]
    if len(markers)>=2:cuts.update(markers)
    points=sorted(cuts)
    return [raw[a:b] for a,b in zip(points,points[1:]) if a<b]

def stutter_span(text):
    return text in {'我','你','他','它','这','那','的','是','和','也','这个','那个','这种','那种','就是','然后','使用','进行','处理','语义','模型','功能','提示词'} or (
        2 <= len(text) <= 12 and text.endswith(('和','的','是')))

PROTECTED = ('可能','我觉得','如果','除非','只有','不要','不能','未必','比如','例如','还没','已经','好吧','吗','呢')

def allowed(old, new, context):
    a, b = core(old), core(new)
    if a == b: return True
    if any(marker in a and marker not in b for marker in PROTECTED): return False
    # Legacy same-span repair plans remain readable; new plans use explicit evidence.
    repair = re.search(r'不对|我是说|说错了', a)
    repaired = re.sub(r'^(?:改成|应该是)', '', a[repair.end():]) if repair else ''
    if repair and b and b == repaired: return True
    if not b and re.fullmatch(r'[嗯呃额啊哦]+|u+m+|u+h+', a): return True
    if b and a == b * 2 and (stutter_span(b) or (len(b) >= 5 and not re.search(r'非常|一定|千万|强调|真的|太', b))): return True
    if b and re.sub(r'^(?:嗯|呃|额|啊)+', '', a) == b: return True
    terms = [row['term'] for row in context.get('terms', [])]
    if b and any(core(term) == b for term in terms) and re.fullmatch(r'[a-z0-9]+', a) and re.fullmatch(r'[a-z0-9]+', b) and difflib.SequenceMatcher(a=a,b=b).ratio() >= .8:
        return True
    matcher = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    changed = False
    for tag, i, j, x, y in matcher.get_opcodes():
        if tag == 'equal': continue
        removed = a[i:j]
        if tag != 'delete' or not removed or not (stutter_span(removed) or removed in {'嗯','呃','额','哦'}): return False
        if removed not in {'嗯','呃','额','哦'} and a[max(0,i-len(removed)):i] != removed and a[j:j+len(removed)] != removed: return False
        changed = True
    return changed

def protected_span(raw, start, end):
    if any(start < m.end() and end > m.start() for m in LITERALS.finditer(raw)):return True
    for m in re.finditer(r'[^。！？!?\n]*(?:口水词|语气词|填充词|这个词|这个字|字面|发音)[^。！？!?\n]*',raw):
        if start<m.end() and end>m.start():return True
    return False

def ambiguous_filler(raw, old, new, start, end):
    removed = core(old)
    if core(new) or not re.fullmatch(r'[嗯额啊哦]+|u+m+|u+h+', removed): return False
    if removed.startswith('u'):
        return bool((start and raw[start-1].isascii() and raw[start-1].isalpha()) or
                    (end < len(raw) and raw[end].isascii() and (raw[end].isalpha() or raw[end] in "-'")))
    tail = raw[end:]
    after = tail.lstrip(' ，,、。.!！?？\n')
    before = raw[:start].rstrip(' ，,、\n')
    if re.fullmatch(r'嗯+',removed) and re.match(r'[，,]',tail):
        clause=re.split(r'[，,。！？!?；;\n]',after,maxsplit=1)[0]
        if len(core(clause))>=4:return False
    if not after or re.match(r'^(?:好(?:的|吧)?|是的|对(?:的)?|可以|没问题|知道|明白|原来|嗯)', after): return True
    if '啊' in removed: return True
    if '哦' in removed:
        return not (re.search(r'(?:能不能|要不要|我想|需要|我们先|把)$',before) and tail and not re.match(r'[。.!！?？]',tail))
    if '额' in removed: return not bool(re.match(r'[，,\s]+',tail))
    # A standalone response (嗯。) stays; an in-clause pause (我们，嗯，先...) can go.
    return bool(re.match(r'[。.!！?？]',tail))

def removes_particle(raw, old, new, start):
    positions = [i for i,c in enumerate(old) if core(c)]
    for tag,i,j,x,y in difflib.SequenceMatcher(a=core(old),b=core(new),autojunk=False).get_opcodes():
        if tag == 'delete' and i < j:
            left, right = start + positions[i], start + positions[j-1] + 1
            if ambiguous_filler(raw, raw[left:right], '', left, right): return True
    return False

def contextual_cleanup(raw, old, new, start, kind):
    """Model decides discourse role; validation limits the edits to local deletions.

    This is not a global filler blacklist. Lexical mentions and quotations stay data.
    """
    # Treat kind as a model hint, not as the authority. A deletion that passes
    # the same discourse/token checks is safe even if tagged spelling/stutter.
    if kind not in {'filler','spelling','stutter'}: return False
    a,b=core(old),core(new)
    if not a or len(a)>80 or any(w in a and w not in b for w in PROTECTED):return False
    sentence_start=max(raw.rfind(p,0,start) for p in '。！？!?\n')+1
    tail=re.split(r'[。！？!?\n]',raw[start:],maxsplit=1)[0]
    sentence=raw[sentence_start:start]+tail
    if re.search(r'口水词|语气词|填充词|这个词|这个字|词语|字面|例子|表示同意|表示惊讶',sentence):return False
    if core(raw) in {'嗯','啊','对','对呀','对啊','是的'}:return False
    changed=False
    for tag,i,j,x,y in difflib.SequenceMatcher(a=a,b=b,autojunk=False).get_opcodes():
        if tag=='equal':continue
        if tag!='delete':return False
        removed=a[i:j]
        if not re.fullmatch(r'(?:那个|这个|这种|那种|就是|然后|怎么说呢|对呀|对啊|对|嗯+|呃+|额|啊+|呀|哦|是的)+',removed):return False
        if removed=='就是':
            positions=[n for n,c in enumerate(old) if core(c)]
            tail=raw[start+positions[j-1]+1:]
            if not re.match(r'[，,。]|(?:要|需要|希望|可以|能|想|先|再|把|让|请|不|会)',tail):return False
        changed=True
    return changed

@lru_cache(maxsize=2048)
def phonetic_syllables(word):
    from pypinyin import lazy_pinyin, Style
    return tuple(lazy_pinyin(word,style=Style.NORMAL))

def grounded_spelling(raw, old, new, context):
    """A proposed homophone must be short, sound alike and occur in supplied data."""
    if not re.fullmatch(r'[\u4e00-\u9fff]{2,8}',old) or not re.fullmatch(r'[\u4e00-\u9fff]{2,8}',new) or len(old)!=len(new):return False
    sources=[raw,context.get('initial',''),context.get('latest','')]+[x['term'] for x in context.get('terms',[])]
    if not any(new in s for s in sources):return False
    if any(w in old+new for w in ['不','没','无','非','零','一','二','两','三','四','五','六','七','八','九','十']):return False
    try:
        a,b=phonetic_syllables(old),phonetic_syllables(new)
    except ImportError:return False
    differences=[(x,y) for x,y in zip(a,b) if x!=y]
    if not differences:return True
    if len(differences)!=1:return False
    x,y=differences[0]
    if len(x)==len(y):return sum(c!=d for c,d in zip(x,y))==1
    short,long=sorted((x,y),key=len)
    return len(long)==len(short)+1 and any(long[:i]+long[i+1:]==short for i in range(len(long)))

def rewrites_learned_alias(old,new,context):
    """Text-only history is not acoustic evidence for this utterance.

    ASR may output either spelling from the audio. The editor cannot turn a
    previous correction into a rule, even when it labels the change differently.
    Explicit, source-evidenced spoken repairs use the separate repairs path.
    """
    a,b=core(old),core(new)
    for row in context.get('personal_aliases',[]):
        heard,term=core(row['heard']),core(row['term'])
        if heard and term and a.count(heard)>b.count(heard) and b.count(term)>a.count(term):return True
    return False

def replace_spans(raw, patches):
    for left,right,new in sorted(patches,reverse=True): raw=raw[:left]+new+raw[right:]
    return raw

def preclean(raw, context=None):
    """Offset-addressed cheap edits also handle repeated identical filler tokens."""
    patches=[]
    names = [row['term'] for row in (context or {}).get('terms', []) if row.get('source') == 'personal' and len(row['term']) >= 2]
    name_spans = [(m.start(), m.end()) for name in names for m in re.finditer(re.escape(name), raw)]
    def add(start,end,new,particle=False):
        if protected_span(raw,start,end) or any(start<r and end>l for l,r,_ in patches): return
        if any(start<r and end>l for l,r in name_spans): return
        if not particle and removes_particle(raw,raw[start:end],new,start): return
        patches.append((start,end,new))
    for m in re.finditer(r'呃+(?!逆)[，,、 \t]*',raw):
        if m.end()<len(raw): add(m.start(),m.end(),'')
    # Long declarative clauses often end in a non-content particle. Standalone
    # responses and lexical/quoted mentions remain protected above.
    for m in re.finditer(r'[啊呀]+(?=[，,。！!；;]|$)',raw):
        clause=re.split(r'[，,。！？!?；;\n]',raw[:m.start()])[-1]
        if len(core(clause))>=6 and not re.search(r'发出|喊出|读作|写作|唱出',clause):add(m.start(),m.end(),'',particle=True)
    for m in re.finditer(r'(^|[，,。！？!?])(?P<filler>(?:对[呀啊]?[，,。]\s*)?(?:然后就是|就是然后)[，,。]\s*)',raw):
        if m.end()<len(raw):add(m.start('filler'),m.end(),'')
    # A broken transition followed by the same transition is a restart, not a
    # second chronological step. Keep the surrounding sentences and their data.
    for m in re.finditer(r'(^|[，,。！？!?])(?P<filler>然后[，,。]\s*(?:对[呀啊]?[，,。]\s*)?然后)[，,]?\s*',raw):
        if m.end()<len(raw):add(m.start('filler'),m.end(),'')
    for m in re.finditer(r'(?<![\w])[Uu][Mm]+[,\s]*|(?<![\w])[Uu][Hh]+[,\s]*|嗯+[，,、 \t]*|额[，, \t]+|哦',raw):
        if m.end()<len(raw):
            start=m.start(); replacement=''
            if m.group(0).lower().startswith(('um','uh')) and re.search(r',\s*$',raw[:start]):
                start=re.search(r',\s*$',raw[:start]).start();replacement=' '
            add(start,m.end(),replacement)
    for m in re.finditer(r'(?P<word>我们|你们|他们|它们|这个|那个|这种|那种|使用|进行|处理|我|你|这|那|更)(?P=word)+',raw):
        add(m.start(),m.end(),m.group('word'))
    for m in re.finditer(r'(?P<word>这个|那个|这种|那种)[，,]\s*(?P=word)',raw):
        add(m.start(),m.end(),m.group('word'))
    # Function-word stutters, not arbitrary repeated characters (看看/人人/非常非常).
    # 成都 + 都 and 成就 + 就 are legitimate word boundaries, not stutters.
    for m in re.finditer(r'(?P<word>都|也|就)(?P=word)+',raw):
        word = m.group('word')
        if word == '都' and re.search(r'[成首京古故陪帝魔大]$',raw[:m.start()]): continue
        if word == '就' and raw[:m.start()].endswith('成'): continue
        add(m.start(),m.end(),word)
    for m in re.finditer(r'语(?=语义)|模(?=模型)|功(?=功能)|提(?=提示词)',raw):
        add(m.start(),m.end(),'')
    # Exact adjacent restarts only. Near matches go to triage and retain new detail.
    for m in re.finditer(r'(?P<clause>[^，,。.!！?？;；\n]{5,60})[，,]\s*(?P=clause)',raw):
        if re.search(r'我|我们|先|需要|希望|应该|可以',m.group('clause')) and not re.search(r'非常|一定|千万|强调|真的', m.group('clause')):
            add(m.start(),m.end(),m.group('clause'))
    text=replace_spans(raw,patches)
    return text,len(patches)

def validate_repair(raw, item, patches):
    if not isinstance(item,dict) or set(item)!={'old','new','cue'}: raise ValueError('Invalid repair')
    old,new,cue=(item[k] for k in ['old','new','cue'])
    if any(not isinstance(v,str) or not v for v in [old,new,cue]): raise ValueError('Invalid repair text')
    if len(old)>160 or len(new)>160 or len(cue)>240 or raw.count(cue)!=1: return None,'source_not_unique'
    cue_base=raw.index(cue)
    common=0
    while common<min(len(old),len(new)) and old[common]==new[common]: common+=1
    # Models sometimes copy the whole sentence or include a following reason.
    # Narrow the proposal to its literal repair clause, never delete that extra data.
    found=None
    starts=[0]+[m.end() for m in re.finditer(r'[，,。.!！?？;；]',cue)]
    for offset in starts:
        fragment=cue[offset:]
        marker=START_CUE.match(fragment) or EN_CUE.match(fragment)
        if not marker or not correction_signal(fragment): continue
        tail=fragment[marker.end():]
        for trim in range(common+1):
            candidate=new[trim:].strip(' \t\r\n，,。.!！?？;；')
            if not candidate or not old[trim:] or tail.count(candidate)!=1: continue
            cs=cue_base+offset;prefix=raw[:cs];target=old[trim:]
            if prefix.count(target)!=1: continue
            left=prefix.index(target);right=left+len(target)
            spoken_prefix=tail[:tail.index(candidate)]
            # A correction may repeat the predicate: "联系李明 ... 联系李敏".
            # Only discard that prefix when it is already present at the target.
            if spoken_prefix and (len(spoken_prefix)>40 or re.search(r'[，,。.!！?？;；]',spoken_prefix) or not raw[:left].endswith(spoken_prefix)): continue
            consumed=len(spoken_prefix)+len(candidate)
            rest=tail[consumed:]
            if rest and not re.match(r'[\s，,。.!！?？;；]',rest):
                suffix=re.split(r'[\s，,。.!！?？;；]',rest,1)[0]
                if not raw[right:].startswith(suffix):continue
                consumed+=len(suffix)
            ce=cs+marker.end()+consumed
            if cs-right>900: continue
            found=(left,right,candidate,cs,ce,target);break
        if found: break
    if found is None:
        found = narrow_numeric_repair(raw, old, new, cue, cue_base)
    if found is None: return None,'missing_repair_evidence'
    left,right,new,cs,ce,old=found
    new = preserve_elliptical_quantity(old, new)
    if protected_span(raw,left,right) or protected_span(raw,cs,ce): return None,'literal_span'
    for word in ['如果','除非','只有','因为','比如','例如','不要','不能']:
        if word in old and word not in new: return None,'repair_drops_constraint'
    # Remove the pause before the cue too, except a sentence boundary that still
    # separates unrelated earlier information. Keep the correction's final punctuation.
    if cs>right and re.fullmatch(r'[，,。.!！?？;；\s]*',raw[right:cs]): cs=right
    elif cs and raw[cs-1] in '，,': cs-=1
    candidates=[(left,right,new),(cs,ce,'')]
    if any(l<r0 and r>l0 for l,r,_ in candidates for l0,r0,_ in patches): return None,'overlap'
    return candidates,None

def preserve_elliptical_quantity(old, new):
    """A spoken quantity without a noun changes the count, not its object.

    The caller has already grounded both spans in this utterance. Keep the
    original noun when the new clause only says a number and the same classifier;
    retain any following instructions verbatim. Explicit new nouns stay explicit.
    """
    number = r'(?:\d+(?:\.\d+)?|[零〇一二两三四五六七八九十百千万亿]+(?:点[零〇一二三四五六七八九]+)?)'
    units = '个条份组次项页本张台人元秒分钟天年月'
    head = re.split(r'[，,。.!！?？;；]', new, 1)[0]
    proposal = re.fullmatch(r'(?P<prefix>.*?)(?P<number>' + number + r')(?P<unit>[' + units + r'])', head)
    if not proposal: return new
    matches = [m for m in re.finditer(r'(?P<number>' + number + r')(?P<unit>[' + units + r'])', old)
               if m['unit'] == proposal['unit']]
    if len(matches) != 1: return new
    source = matches[0]
    noun = old[source.end():]
    if not noun or len(noun) > 32 or re.search(r'[\s，,。.!！?？;；]|' + number, noun): return new
    if proposal['prefix'] and proposal['prefix'] != old[:source.start()]: return new
    return old[:source.start()] + proposal['number'] + old[source.end('number'):] + new[len(head):]

def narrow_numeric_repair(raw, old, new, cue, cue_base):
    """A model may copy unchanged context into new; change only a grounded number.

    Example: old='先保留十个测试样本', new='先保留十二个测试样本',
    later speech='改成十二个样本'. The original '测试' stays in place.
    """
    number = r'(?:\d+(?:\.\d+)?|[零〇一二两三四五六七八九十百千万亿]+(?:点[零〇一二三四五六七八九]+)?)'
    source = raw[:cue_base]
    if source.count(old) != 1: return None
    for a in re.finditer(number, old):
        for b in re.finditer(number, new):
            if a[0] == b[0] or old[:a.start()] != new[:b.start()] or old[a.end():] != new[b.end():]: continue
            marker = START_CUE.match(cue) or EN_CUE.match(cue)
            if not marker or not correction_signal(cue): continue
            tail = cue[marker.end():]
            phrase = re.split(r'[，,。.!！?？;；]', tail, 1)[0].strip()
            matches = list(re.finditer(number, phrase))
            if len(matches) != 1 or matches[0][0] != b[0]: continue
            spoken = matches[0]
            prefix, suffix = phrase[:spoken.start()], phrase[spoken.end():]
            if prefix and not old[:a.start()].endswith(prefix): continue
            original_suffix = old[a.end():]
            # Consume a repeated unit/noun only when all its words already occur
            # in the original slot, in order. Never swallow a new constraint.
            if not suffix or not original_suffix or suffix[0] != original_suffix[0]: continue
            if suffix[0] not in '个条份组次项页本张台人元秒分钟天年月': continue
            matching = difflib.SequenceMatcher(a=original_suffix,b=suffix,autojunk=False)
            removed = ''
            valid = True
            for tag,i,j,x,y in matching.get_opcodes():
                if tag == 'equal': continue
                if tag != 'delete': valid = False; break
                removed += original_suffix[i:j]
            if not valid or re.search(r'不|无|非|未|低|高|大|小|新|旧|仅|限|至|约|每|最|以上|以下|至少|最多', removed): continue
            left = source.index(old)+a.start()
            if cue_base-left-len(a[0]) > 900: continue
            return left,left+len(a[0]),b[0],cue_base,cue_base+marker.end()+len(phrase),a[0]
    return None

def validate_restart(raw, units, item, patches):
    """Delete only an explicitly withdrawn utterance and its redundant restart.

    The model identifies discourse scope; literal sentence ids and the spoken
    cue provide evidence. The later statement is kept verbatim, never generated.
    """
    if not isinstance(item,dict) or set(item)!={'drop','keep','cue'}: return None,'invalid_restart'
    drop,keep,cue=item['drop'],item['keep'],item['cue']
    for ids,limit in [(drop,2),(keep,3)]:
        if not isinstance(ids,list) or not 1<=len(ids)<=limit or any(type(i)is not int or not 0<=i<len(units) for i in ids):return None,'invalid_restart_ids'
        if ids!=list(range(ids[0],ids[-1]+1)):return None,'noncontiguous_restart'
    if drop[-1]+1!=keep[0]:return None,'nonadjacent_restart'
    marker=RESTART_HEAD.match(units[drop[-1]])
    if not marker or not isinstance(cue,str) or not core(cue) or cue not in marker[0]:return None,'missing_restart_cue'
    start=sum(map(len,units[:drop[0]]));end=sum(map(len,units[:keep[0]]))
    kept=''.join(units[i] for i in keep)
    if end-start>500 or len(core(kept))<6:return None,'restart_scope'
    if protected_span(raw,start,end):return None,'literal_span'
    if any(start<r and end>l for l,r,_ in patches):return None,'overlap'
    payload=units[drop[-1]][marker.end():].strip(' \t\r\n。！？!?；;')
    earlier=''.join(units[i] for i in drop[:-1])
    # A redundant transition must refer to the same task as the final wording.
    def shared_content(a,b):
        matches=difflib.SequenceMatcher(a=a,b=b,autojunk=False).get_matching_blocks()
        content=[m.size for m in matches if m.size>=2 and a[m.a:m.a+m.size] not in {'我觉得','你先看','你看一下','我们先','重新说','重说','重说一遍','你先','我们','一下','一遍'}]
        return bool(content and (max(content)>=3 or sum(content)>=4))
    evidence,remaining=core(payload or earlier),core(kept)
    if not (shared_content(evidence,remaining) or shared_content(evidence.replace('重新','重'),remaining.replace('重新','重'))):return None,'unrelated_restart'
    # Keep new reasons/constraints in the transition. A withdrawal is not
    # permission to summarize away a budget, condition or independent instruction.
    details=r'^(?:因为|由于|为了|如果|除非|只有|只要|预算|上限|下限|至少|最多|不要|不能|禁止|必须|记得|保留|包含|还要|另外|同时|但是|不过|而且|并且)'
    old_details=r'^(?:如果|除非|只有|只要|预算|上限|下限|至少|最多|不要|禁止|必须|记得)'
    for text,pattern in [(payload,details),(earlier,old_details)]:
        for clause in re.split(r'[，,。！？!?；;]',text):
            if re.search(pattern,clause.strip()) and core(clause) not in core(kept):return None,'restart_drops_detail'
    from numerals import normalize
    normalized=normalize(payload)[0]
    numbers=re.findall(r'\d+(?:\.\d+)?',normalized)
    remaining=re.findall(r'\d+(?:\.\d+)?',normalize(kept)[0])
    if any(n not in remaining for n in numbers):return None,'restart_drops_number'
    return (start,end,''),None

def restart_candidates(raw):
    """Supply source-checked ids to the small model; it still decides intent."""
    units=split_units(raw); result=[]
    for i,unit in enumerate(units[:-1]):
        marker=RESTART_HEAD.match(unit)
        if i==0 or not marker:continue
        item={'drop':[i-1,i],'keep':[i+1],'cue':marker[0].strip(' \t\r\n，,。')}
        if validate_restart(raw,units,item,[])[0] is not None:result.append(item)
    return result[:3]

def apply_plan(raw, plan, context):
    if not isinstance(plan,dict) or not {'edits','breaks','bullets'}<=set(plan) or set(plan)-{'edits','repairs','restarts','breaks','bullets'}: raise ValueError('Invalid edit plan fields')
    units=split_units(raw)
    if ''.join(units)!=raw: raise ValueError('Invalid source segmentation')
    if not isinstance(plan['edits'],list) or len(plan['edits'])>24: raise ValueError('Too many edits')
    repairs=plan.get('repairs',[])
    if not isinstance(repairs,list) or len(repairs)>6: raise ValueError('Too many repairs')
    restarts=plan.get('restarts',[])
    if not isinstance(restarts,list) or len(restarts)>3:raise ValueError('Too many restarts')
    patches,rejected=[],[]; repair_count=0; restart_count=0; groups=[]
    for item in restarts:
        candidate,reason=validate_restart(raw,units,item,patches)
        if reason:rejected.append({'restart':item,'reason':reason})
        else:patches.append(candidate);restart_count+=1
    for item in repairs:
        candidates,reason=validate_repair(raw,item,patches)
        if reason=='overlap':
            fresh,failure=validate_repair(raw,item,[])
            if not failure:
                left,right,new=fresh[0]
                for group_index,(target,cue_span) in enumerate(groups):
                    if cue_span[0]<=left and right<=cue_span[1] and core(target[2])==core(raw[left:right]):
                        added=fresh[1]
                        if any(added[0]<r and added[1]>l for l,r,value in patches if value):break
                        patches[patches.index(target)]=(target[0],target[1],new)
                        # Chain corrections refer to a phrase already consumed by the
                        # previous cue. Extend only deletion spans, keeping intervening facts.
                        empty=[p for p in patches if not p[2]]+[added]
                        nonempty=[p for p in patches if p[2]]
                        merged=[]
                        for l,r,_ in sorted(empty):
                            if merged and l<=merged[-1][1]:merged[-1]=(merged[-1][0],max(r,merged[-1][1]),'')
                            else:merged.append((l,r,''))
                        patches=nonempty+merged;groups[group_index]=((target[0],target[1],new),added);repair_count+=1;reason=None;candidates=None;break
        if reason: rejected.append({**item,'reason':reason})
        elif candidates is not None: patches.extend(candidates);groups.append((candidates[0],candidates[1]));repair_count+=1
    guard_source=replace_spans(raw,patches)
    for edit in plan['edits']:
        reason=None
        if not isinstance(edit,dict) or not {'old','new'}<=set(edit) or set(edit)-{'old','new','kind'}: raise ValueError('Invalid edit')
        old,new=edit['old'],edit['new']
        if not isinstance(old,str) or not isinstance(new,str): raise ValueError('Invalid edit text')
        if old==new: continue
        if not old or len(old)>120 or len(new)>140 or raw.count(old)!=1: reason='source_not_unique'
        start=raw.find(old);end=start+len(old)
        # Some models put the already-adjacent suffix in new instead of leaving
        # it outside old. Recover only an independently valid filler deletion;
        # never duplicate that suffix or reinterpret a substantive replacement.
        if start>=0 and new and raw[end:].startswith(new) and contextual_cleanup(raw,old,'',start,edit.get('kind')):
            new=''
        if core(old)==core(new) and any(p in old and p not in new for p in '。！？!?'):reason='sentence_boundary_change'
        if not reason and protected_span(raw,start,end):reason='literal_span'
        if not reason and rewrites_learned_alias(old,new,context):reason='learned_alias_requires_audio'
        discourse=contextual_cleanup(raw,old,new,start,edit.get('kind'))
        spelling=edit.get('kind')=='spelling' and grounded_spelling(raw,old,new,context)
        if not spelling and edit.get('kind')=='spelling':
            # Models sometimes include unchanged neighboring words in a spelling
            # edit. Validate the actual short changed word against the sources.
            left=0;right=0
            while left<min(len(old),len(new))-2 and old[left]==new[left]:left+=1
            while right<min(len(old),len(new))-left-2 and old[len(old)-right-1]==new[len(new)-right-1]:right+=1
            spelling=grounded_spelling(raw,old[left:len(old)-right],new[left:len(new)-right],context)
        if not reason and not discourse and removes_particle(raw,old,new,start):reason='meaningful_particle'
        if not reason and any(start<right and end>left for left,right,_ in patches):reason='overlap'
        if not reason and not (discourse or spelling or allowed(old,new,context)):reason='unsupported_rewrite'
        if reason:rejected.append({**edit,'reason':reason})
        else:patches.append((start,end,new))
    outputs,offset=[],0
    untouched=set()
    for unit in units:
        end=offset+len(unit);pieces=[];cursor=offset;touched=False
        for left,right,new in sorted(patches):
            if right<=offset or left>=end:continue
            touched=True
            pieces.append(raw[cursor:max(cursor,left)])
            if left>=offset:pieces.append(new)
            cursor=min(end,right)
        if not touched:untouched.add(len(outputs))
        pieces.append(raw[cursor:end]);outputs.append(''.join(pieces));offset=end
    for field in ['breaks','bullets']:
        ids=plan[field]
        if not isinstance(ids,list) or any(type(i)is not int or i<0 or i>=len(units) for i in ids) or len(set(ids))!=len(ids):raise ValueError('Invalid layout ids')
    breaks,bullets=set(plan['breaks']),set(plan['bullets'])
    explicit = explicit_list_ids(units)
    # Default to continuous prose. The model cannot turn every sentence into a paragraph/list.
    if context.get('layout_policy', 'minimal') != 'paragraphs': breaks = set()
    else:
        accepted, since = set(), ''
        for i, unit in enumerate(outputs):
            since += unit
            tail = ''.join(outputs[i+1:])
            if i in breaks and len(core(since)) >= 90 and len(core(tail)) >= 60 and not re.search(r'[的和与或者及]。?$',unit):
                accepted.add(i); since = ''
        breaks = accepted
    bullets = set(explicit) if len(explicit) >= 2 else set()
    if len(bullets)<2:bullets=set()
    rendered=''
    for i,text in enumerate(outputs):
        if not core(text):
            if i in untouched:
                rendered+=text;continue
            punctuation=text.strip()
            if rendered and punctuation and punctuation[0] in '。.!！?？;；' and rendered[-1] not in '。.!！?？;；\n':
                rendered+=punctuation[0]
            continue
        if i in bullets:
            if rendered and not rendered.endswith('\n'):rendered+='\n'
            rendered+='- '+text.strip()+'\n'
        else:rendered+=text
        if i in breaks and rendered and not rendered.endswith('\n\n'):rendered+='\n\n'
    return rendered.strip(), {'applied_edits':len(patches),'repair_count':repair_count,'restart_count':restart_count,'rejected_edits':rejected,'guard_source':guard_source,'plan':plan}

def explicit_list_ids(units):
    return [i for i,s in enumerate(units) if re.match(r'^\s*(?:第[一二三四五六七八九十0-9]+[，,、]|首先[，,、]|其次[，,、]|一是|二是|三是)',s)]

def simple_layout(raw):
    units=split_units(raw)
    ids=explicit_list_ids(units)
    if len(ids)>=2:
        return apply_plan(raw,{'edits':[],'breaks':[],'bullets':ids},{})[0]
    return raw
