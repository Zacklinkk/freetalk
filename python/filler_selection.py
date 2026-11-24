"""Source-addressed filler decisions: the model selects IDs, never rewrites text.

The prompt is prompts/filler-selection.txt.
"""
import json
import re
from edits import core, protected_span, contextual_cleanup, replace_spans


def candidates(raw, scene='', keep=()):
    """Filler words the model may choose to drop. `keep` are words the user put back before."""
    rows = []
    pattern = r'对[呀啊]?[，,。]\s*然后[，,]?\s*|就是说[哦啊][，,]?\s*|然后|就是|那个|这个|对呀|对啊|[嗯呃哦啊呀][，,]?\s*'
    for m in re.finditer(pattern,raw):
        a,b=m.span(); old=m[0]; new=''
        if old.startswith('就是说'): new='就是说' + ('，' if '，' in old else ',' if ',' in old else '')
        # A particle that ends a clause (好的呀，) is tone, not a pause: the
        # comma after it separates two clauses and stays. In a chat with a
        # person the tone itself is kept.
        if old[0] in '啊呀' and a and core(raw[a-1]):
            if scene == 'conversation': continue
            old = old[0]; b = a+1
        if scene == 'conversation' and old in {'对呀', '对啊'}: continue
        if core(old) in keep: continue
        # Sequential 然后 is refused by contextual_cleanup (see sequential_then).
        if protected_span(raw,a,b) or not contextual_cleanup(raw,old,new,a,'filler',scene):continue
        before,after=raw[max(0,a-40):a],raw[b:b+50]
        # A missing demonstrative can change which file/object is intended.
        if old in {'这个','那个'} and not re.search(r'的$',before):continue
        rows.append(dict(id='d'+str(len(rows)+1),start=a,end=b,old=old,new=new,before=before,after=after))
        if len(rows)>=32:break
    return rows


def selection_input(raw, rows):
    return json.dumps({'sentences':raw, 'candidates':[{k:r[k] for k in ('id','old','before','after')} for r in rows]}, ensure_ascii=False)


def apply_selection(raw, rows, selection):
    if not isinstance(selection,dict) or set(selection)!={'drop'} or not isinstance(selection['drop'],list):
        raise ValueError('Invalid filler selection')
    ids=selection['drop']; by_id={r['id']:r for r in rows}
    if len(ids)>32 or any(not isinstance(i,str) or i not in by_id for i in ids):
        raise ValueError('Unknown filler candidate')
    patches=[]
    for key in dict.fromkeys(ids):
        r=by_id[key];a,b=r['start'],r['end']
        if raw[a:b]!=r['old'] or protected_span(raw,a,b) or not contextual_cleanup(raw,r['old'],r['new'],a,'filler'):
            continue
        patches.append((a,b,r['new']))
    return replace_spans(raw,patches),len(patches)
