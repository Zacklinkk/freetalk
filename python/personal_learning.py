"""Reviewed dictations, resumable local cleanup adapters, and their acceptance tests."""
import argparse
from collections import Counter
from difflib import SequenceMatcher
import hashlib
import json
import math
import os
from pathlib import Path
import re
import signal
import tempfile
import time

MIN_TRAIN, MIN_TEST = 8, 4
FLAGS = ('retain', 'train', 'voice', 'idle', 'auto')
paused = False


def read(path, default=None):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(dir=path.parent, mode='w', delete=False) as out:
        json.dump(value, out, ensure_ascii=False, allow_nan=False)
        out.flush()
        os.fsync(out.fileno())
    os.replace(out.name, path)


def fingerprint(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False).encode()).hexdigest()


def clean(text):
    return re.sub(r'\s+', ' ', text.strip())


def label(row):
    """Use the confirmed sent text for both tasks; an ASR label also needs matching audio."""
    if not all(isinstance(row.get(k),str) for k in ('reviewedFinal','text','raw')):
        return '待核对'
    final = clean(row.get('reviewedFinal') or '')
    inserted = clean(row.get('text') or '')
    if not final or not inserted or not row.get('raw'):
        return '待核对'
    if final == inserted:
        return '未改动'
    if len(final) > 4000 or len(inserted) > 4000 or not 0.6 <= len(final) / len(inserted) <= 1.5:
        return '长度变化'
    if SequenceMatcher(None, inserted, final, autojunk=False).ratio() < .5:
        return '相似度低于50%'
    if final.startswith(inserted) and len(final) - len(inserted) > 2:
        return '追加内容'
    return 'accepted'


def reviewed(support):
    result, counts = [], Counter()
    for file in (support/'learning'/'samples').glob('*/record.json'):
        try:
            row = read(file)
        except (OSError, ValueError):
            counts['文件无法读取'] += 1
            continue
        if (not isinstance(row, dict) or row.get('id') != file.parent.name or
                not isinstance(row.get('createdAt'),str) or len(row['createdAt']) < 10):
            continue
        reason = label(row)
        counts[reason] += 1
        if reason == 'accepted':
            row['audio'] = str(file.with_name('audio.wav')) if file.with_name('audio.wav').is_file() else None
            result.append(row)
    return sorted(result, key=lambda r: (r['createdAt'], r['id'])), counts


def split(rows):
    """Forward time split by day. Repeated raw utterances stay out of the holdout."""
    days = sorted({r['createdAt'][:10] for r in rows})
    if len(days) < 2:
        return [], []
    boundary = days[max(1, min(len(days)-1, int(.8*len(days))))]
    train, test = [], []
    def key(r):
        return re.sub(r'[\W_]', '', r['raw'].casefold())
    seen = set()
    for row in rows:
        k = key(row)
        if k and k not in seen:
            (train if row['createdAt'][:10] < boundary else test).append(row)
            seen.add(k)
    return train, test


def edits_for(source, target):
    """Local proposals only. apply_plan and the complete product pipeline must reproduce the target."""
    from edits import core
    ops = []
    for op, a, b, c, d in SequenceMatcher(None, source, target, autojunk=False).get_opcodes():
        if op == 'equal':
            continue
        old, new = source[a:b], target[c:d]
        # Locate repeated fragments and insertions with a little unchanged source context.
        while (not old or source.count(old) != 1) and a > 0 and len(old) < 48:
            a -= 1
            new = source[a] + new
            old = source[a:b]
        if not old or source.count(old) != 1:
            return []
        kind = 'punctuation' if core(old) == core(new) else 'filler' if not core(new) else 'spelling'
        ops.append(dict(kind=kind, old=old, new=new))
    return ops


def training_examples(rows, preferences=()):
    """Run production routing without inference. Keep only exact, validated edit labels."""
    from engine import Editor
    from edits import preclean
    from filler_selection import apply_selection, selection_input

    class Teacher(Editor):
        def plan_budget(self, raw):
            # This path replays the known target; it generates no model tokens.
            return 0

        def prepare_prefix(self, base):
            return None, None

        def _local_plan(self, base, prefix, cache, user, max_tokens, timeout):
            plan = dict(repairs=[], edits=edits_for(self.source, self.target), breaks=[], bullets=[])
            return self.remember(base, user, plan), 'stop', None

        def remember(self, base, user, plan):
            target = json.dumps(plan, ensure_ascii=False, separators=(',', ':'))
            self.example = {'messages': [*base, {'role':'user','content':user}, {'role':'assistant','content':target}]}
            return target

        def select_fillers(self, raw, candidates, timeout):
            removed = {i for op, a, b, _, _ in SequenceMatcher(None, raw, self.target, autojunk=False).get_opcodes()
                       if op in ('delete', 'replace') for i in range(a, b)}
            plan = {'drop':[r['id'] for r in candidates if any(i in removed for i in range(r['start'],r['end']))]}
            text, count = apply_selection(raw, candidates, plan)
            self.remember(self.filler_base, selection_input(raw, candidates), plan)
            return text, dict(applied_edits=count, model_used=True)

    teacher = Teacher.__new__(Teacher)
    teacher.mode, teacher.remote, teacher.emit = 'edits', None, lambda event: None
    teacher.set_preferences(preferences)
    examples = []
    for row in rows:
        teacher.source = preclean(row['raw'], {})[0]
        teacher.target = row['reviewedFinal'].strip()
        teacher.example = None
        text, meta = teacher.edit(row['raw'], {})
        if teacher.example and text.strip() == teacher.target and not meta.get('rejected_edits'):
            examples.append(teacher.example)
    return examples


def quality(prediction, target):
    # Levenshtein distance and, for tied alignments, fewest reference deletions.
    prev = [(j,0) for j in range(len(prediction)+1)]
    for i, a in enumerate(target, 1):
        cur = [(i,i)]
        for j,b in enumerate(prediction, 1):
            e,d = prev[j]; insert = cur[-1]; subst = prev[j-1]
            cur.append(min((e+1,d+1), (insert[0]+1,insert[1]), (subst[0]+(a!=b),subst[1])))
        prev = cur
    return prev[-1]


def p95(values):
    ordered = sorted(values)
    return ordered[math.ceil(.95*len(ordered))-1] if ordered else None


def evaluate(model, adapter, rows, preferences):
    from engine import Editor
    from cleanup_eval import load, context, flat
    editor = Editor(model, adapter_path=str(adapter) if adapter else None, preferences=preferences)
    checks = [{'id':r['id'], 'raw':r['raw'], 'gt':r['reviewedFinal'],'personal':True} for r in rows] + load()
    report = []
    for case in checks:
        check_pause()
        text, _ = editor.edit(case['raw'], context(case))
        pred, target = flat(text), flat(case['gt'])
        errors, dels = quality(pred, target)
        report.append(dict(id=case['id'], real=case.get('personal',False), chars=len(target), errors=errors,
                           deletions=dels, exact=target==pred))
    return report


def acceptance(base, candidate):
    if not base or [r['id'] for r in base] != [r['id'] for r in candidate]:
        return False
    before, after = ([r for r in run if r['real']] for run in (base, candidate))
    return (len(after) >= MIN_TEST and sum(r['errors'] for r in after) < sum(r['errors'] for r in before)
            and sum(r['deletions'] for r in after) <= sum(r['deletions'] for r in before)
            and all(not old['exact'] or new['exact'] for old,new in zip(base,candidate)))


def model_key(config, field='cleanupModel'):
    model = Path(config[field]).resolve()
    return fingerprint([str(model), [(f.name,f.stat().st_size,f.stat().st_mtime_ns) for f in sorted(model.glob('*.safetensors'))]])


def candidate_dir(support, key):
    if not isinstance(key,str) or not re.fullmatch('[a-f0-9]{24}',key):
        raise ValueError('候选标识无效')
    return support/'learning'/'candidates'/key


def active_adapter(support, config, lane='cleanup'):
    if not support: return None
    s = Path(support)
    try:
        state = read(s/'learning'/('active-asr.json' if lane=='asr' else 'active.json'), {})
        key = state.get('id') if isinstance(state, dict) else None
        if not key: return None
        folder = candidate_dir(s, key); info = read(folder/'report.json', {})
        if info.get('passed') and info.get('lane','cleanup') == lane and info.get('base') == model_key(config, 'asrModel' if lane=='asr' else 'cleanupModel') and (folder/'adapters.safetensors').is_file():
            return str(folder)
    except (OSError, ValueError):
        pass
    return None


def check_pause():
    if paused:
        raise InterruptedError('已暂停，本机模型可以恢复')


def training(folder, path, examples):
    import mlx.core as mx
    import mlx.nn as nn
    import mlx.optimizers as optim
    from mlx.utils import tree_flatten
    from mlx_lm import load
    from mlx_lm.tuner.trainer import default_loss
    from mlx_lm.tuner.utils import linear_to_lora_layers
    mx.set_memory_limit(7*2**30); mx.set_cache_limit(256*2**20)
    mx.random.seed(23)
    model,tok = load(path)
    model.freeze()
    params = dict(rank=8, dropout=0., scale=16.)
    linear_to_lora_layers(model, 4, params)
    write(folder/'adapter_config.json',dict(num_layers=4,fine_tune_type='lora',lora_parameters=params))
    encoded = []
    for example in examples:
        turns = example['messages']
        prompt = tok.apply_chat_template(turns[:-1], tokenize=True, add_generation_prompt=True, enable_thinking=False)
        response = tok.encode(turns[-1]['content'],add_special_tokens=False) + [tok.eos_token_id]
        if len(prompt)+len(response) <= 3072:
            encoded.append((list(prompt)+response,len(prompt)))
    if len(encoded) < MIN_TRAIN:
        raise ValueError('与实际提示词匹配且长度合适的训练样本还不足 8 条')
    weights = folder/'adapters.safetensors'
    step = 0
    if weights.exists():
        _, meta = mx.load(str(weights),return_metadata=True)
        step = int(meta['step'])
        model.load_weights(str(weights),strict=False)
    # SGD without momentum and no dropout: the weights and sample position are the full checkpoint.
    optimizer = optim.SGD(learning_rate=.0001)
    loss_and_grad = nn.value_and_grad(model, default_loss)
    total = min(64,len(encoded)*2)
    for i in range(step, total):
        check_pause()
        ids, start = encoded[i % len(encoded)]
        (_, _), grad = loss_and_grad(model,mx.array([ids]),mx.array([[start,len(ids)-1]]))
        optimizer.update(model,grad)
        saved = dict(tree_flatten(model.trainable_parameters()))
        mx.eval(saved)
        temp = folder/'next.safetensors'
        mx.save_safetensors(str(temp),saved,metadata={'step':str(i+1)})
        os.replace(temp,weights)
    return total


def local_preferences(support):
    import prompt_files
    from engine import load_preferences
    prompt_files.overrides = support/'prompts'
    return load_preferences(support)


def fit(support, config):
    from prompt_files import source
    rows, counts = reviewed(support)
    train, test = split(rows)
    preferences = local_preferences(support)
    from learning_augmentation import training_practice
    examples = training_examples(train,preferences)
    if len(examples)<MIN_TRAIN or len(test)<MIN_TEST:
        return f'需要至少 8 条可生成编辑计划的训练样本和另一天的 4 条核对样本。目前 {len(examples)} / {len(test)}。'
    examples += training_examples(training_practice(support,train,test),preferences)[:len(examples)//4]
    basekey = model_key(config)
    from cleanup_eval import load
    key = fingerprint([basekey,preferences,examples,[(r['id'],r['raw'],r['reviewedFinal']) for r in test],load(),
                       [source(n) for n in ('edit-rules.txt','edit-plan.txt','filler-selection.txt','restart-plan.txt')]])[:24]
    folder = candidate_dir(support,key); folder.mkdir(parents=True,mode=0o700,exist_ok=True)
    existing = read(folder/'report.json')
    if not existing:
        import gc
        import mlx.core as mx
        steps = training(folder,config['cleanupModel'],examples)
        gc.collect(); mx.clear_cache(); check_pause()
        base = evaluate(config['cleanupModel'],None,test,preferences)
        gc.collect(); mx.clear_cache(); check_pause()
        cand = evaluate(config['cleanupModel'],folder,test,preferences)
        existing = dict(id=key,base=basekey,steps=steps,passed=acceptance(base,cand),baseline=base,candidate=cand)
        write(folder/'report.json',existing)
    write(support/'learning'/'latest.json',{'id':key})
    return '候选通过文字评测，可以手动试用并测量输入延迟。' if existing['passed'] else '候选未改善核对稿或出现回归，继续使用原模型。'


def activate(support, config, *, automatic=False, lane='cleanup'):
    suffix = '-asr' if lane == 'asr' else ''
    latest = support/'learning'/f'latest{suffix}.json'
    active = support/'learning'/f'active{suffix}.json'
    key = read(latest,{}).get('id')
    folder = candidate_dir(support,key)
    report = read(folder/'report.json',{})
    if not report.get('passed') or report.get('lane','cleanup') != lane or report.get('base')!=model_key(config,'asrModel' if lane=='asr' else 'cleanupModel'): raise ValueError('候选未通过本机质量评测')
    if automatic:
        if read(active, {}) != {'id':key, 'phase':'trial'}:
            return False
        # Use verified insertions from local cleanup only, on the same base model.
        history=read(support/'history.json',[])
        peer = 'cleanup' if lane == 'asr' else 'asr'
        peer_file = 'active-asr.json' if peer == 'asr' else 'active.json'
        peer_id = read(support/'learning'/peer_file, {}).get('id')
        def lat(group):
            return [r['stopToInputSeconds'] for r in history
                    if (r.get(lane+'Adapter') or 'base') == group and r.get(lane+'Base') == report['base']
                    and r.get(peer+'Adapter') == peer_id and (r.get('cleanupEngine') == 'local' or (lane=='asr' and not r.get('modelUsed')))
                    and isinstance(r.get('stopToInputSeconds'),(int,float)) and math.isfinite(r['stopToInputSeconds'])
                    and r['stopToInputSeconds'] >= 0]
        old,new=lat('base'),lat(key)
        if (min(len(old),len(new))<20 or p95(new)>p95(old)
                or len([r for r in report['candidate'] if r['real']])<20):return False
    write(active,{'id':key,'phase':'accepted' if automatic else 'trial'})
    return True


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['status','samples','export-asr','train','trial','rollback','train-asr','trial-asr','rollback-asr'])
    parser.add_argument('--support',type=Path,required=True)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args(); s=args.support.resolve()
    os.umask(0o077)
    flags=read(s/'learning-settings.json',{})
    if args.action.startswith('rollback'):
        active='active-asr.json' if args.action.endswith('-asr') else 'active.json'
        write(s/'learning'/active,{'phase':'rollback'});print('已恢复基础模型');return
    if args.action=='status':
        _,counts=reviewed(s);print(json.dumps(counts,ensure_ascii=False));return
    if args.action=='samples':
        rows,_=reviewed(s)
        train,test=split(rows)
        print(json.dumps([{'id':r['id'],'date':r['createdAt'][:10],'split':part,'audio_aligned':bool(r.get('audioAligned') and r.get('audio'))}
                          for part,items in [('train',train),('holdout',test)] for r in items],ensure_ascii=False))
        return
    if not flags.get('train'):raise ValueError('请先在设置中允许本地训练')
    config=read(s/'config.json')
    if args.action=='export-asr':
        if not args.output:parser.error('--output is required')
        rows,_=reviewed(s)
        with args.output.open('x',encoding='utf-8') as out:
            for r in rows:
                if r.get('audioAligned') is True and r['audio']:
                    out.write(json.dumps({'audio':r['audio'],'text':r['reviewedFinal']},ensure_ascii=False)+'\n')
        print('已导出经核对的 ASR 音频与发送稿');return
    if args.action.startswith('trial'):
        activate(s,config,lane='asr' if args.action.endswith('-asr') else 'cleanup');print('已启用手动试用的候选');return
    import fcntl
    def stop(*_):
        global paused
        paused=True
    for sig in (signal.SIGTERM,signal.SIGINT):signal.signal(sig,stop)
    with (s/'inference.lock').open('a') as lock:
        for _ in range(40):
            check_pause()
            try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB);break
            except BlockingIOError:time.sleep(.1)
        else:raise ValueError('本机推理仍在使用中')
        lane='asr' if args.action=='train-asr' else 'cleanup'
        if lane=='asr':
            from asr_learning import fit as fit_asr
            message=fit_asr(s,config)
        else:
            message=fit(s,config)
        print(message,flush=True)
        if read(s/'learning-settings.json',{}).get('auto'):
            try:
                if activate(s,config,automatic=True,lane=lane):
                    print('候选的质量和输入延迟通过验收，已确认采用。')
            except ValueError:
                pass



if __name__=='__main__':
    try:main()
    except (ValueError,OSError,RuntimeError) as err: print(str(err));raise SystemExit(1)
