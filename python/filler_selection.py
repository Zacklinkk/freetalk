"""Source-addressed filler decisions: the model selects IDs, never rewrites text.

The prompt is prompts/filler-selection.txt.
"""
import json
import re
from edits import protected_span, contextual_cleanup, replace_spans


def candidates(raw):
    rows = []
    pattern = r'对[呀啊]?[，,。]\s*然后[，,]?\s*|就是说[哦啊][，,]?\s*|然后|就是|那个|这个|对呀|对啊|[嗯呃哦啊呀][，,]?\s*'
    for m in re.finditer(pattern,raw):
        a,b=m.span(); old=m[0]; new=''
        if old.startswith('就是说'): new='就是说' + ('，' if '，' in old else ',' if ',' in old else '')
        if protected_span(raw,a,b) or not contextual_cleanup(raw,old,new,a,'filler'):continue
        before,after=raw[max(0,a-40):a],raw[b:b+50]
        if old == '然后':
            clause = re.split(r'[。！？!?\n]',before)[-1].rstrip(' ，,')
            # A small model sometimes calls any connective a filler. Keep
            # sequential clauses unless this is a clearly redundant restart.
            redundant = re.match(r'中间|最后|之后|接下来',after) or clause in {'我们','我','你','大家'}
            if clause and not redundant: continue
        # A missing demonstrative can change which file/object is intended.
        if old in {'这个','那个'} and not re.search(r'的$',before):continue
        rows.append(dict(id='d'+str(len(rows)+1),start=a,end=b,old=old,new=new,before=before,after=after))
        if len(rows)>=32:break
    return rows


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
