"""Human-approved practice batches. Real utterances and reference audio stay local."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

from personal_learning import fingerprint, read, reviewed, split, write

CATEGORIES = ('英文缩写', '数字与版本', '自我纠正', '分点分段')
GUIDE = ('为中文口述构造独立的短句和忠实的整理稿，包含应改和应保留的反例。'
         '保持数量、条件、否定、事实和语序。只输出 JSON 数组，每项仅有 spoken 和 cleaned。')


def checked_plan(root, key):
    if not re.fullmatch('[a-f0-9]{24}', key):
        raise ValueError('提案编号无效')
    folder = root / key
    plan = read(folder/'proposal.json')
    if not isinstance(plan, dict) or fingerprint(plan)[:24] != key:
        raise ValueError('提案不存在或内容已变更')
    return folder, plan


def propose(support, category, topic, sample, count):
    if category not in CATEGORIES or not 1 <= count <= 12 or not 1 <= len(topic.strip()) <= 80 or not topic.isprintable():
        raise ValueError('主题须为 1–80 个可显示字符，每批 1–12 组')
    rows, _ = reviewed(support)
    training, _ = split(rows)
    if sample not in {r['id'] for r in training}:
        raise ValueError('请选择经核对且已分到训练集的样本，保留集不能生成练习')
    plan = dict(category=category, public_topic=topic.strip(), source=sample, count=count)
    key = fingerprint(plan)[:24]
    write(support/'learning'/'practice'/key/'proposal.json', plan)
    return key


def prompt(plan):
    return GUIDE + '\n' + json.dumps(dict(category=plan['category'], topic=plan['public_topic'], count=plan['count']), ensure_ascii=False)


def parse_gemini(data, count):
    envelope = json.loads(data)
    events = envelope if isinstance(envelope, list) else [envelope]
    last = next((e for e in reversed(events) if isinstance(e, dict) and e.get('type') == 'result'), {})
    if last.get('is_error', True) or not any('gemini' in m.lower() for m in (last.get('modelUsage') or {})):
        raise ValueError('DUCC 未确认由 Gemini 成功生成')
    text = re.sub(r'^\s*```(?:json)?\s*|\s*```\s*$', '', last['result'])
    pairs = json.loads(text)
    if (not isinstance(pairs, list) or len(pairs) != count or any(
        not isinstance(r,dict) or set(r) != {'spoken','cleaned'} or
        any(not isinstance(v,str) or not v.strip() or len(v)>400 for v in r.values()) for r in pairs)):
        raise ValueError('生成结果的字段、长度或组数不符')
    return pairs


def generate(folder, plan, model):
    if 'gemini' not in model.lower():
        raise ValueError('请选择 DUCC 提供的 Gemini 模型名')
    if (folder/'text.json').exists():
        raise ValueError('这批文本已经生成')
    binary = shutil.which('ducc')
    if not binary:
        raise ValueError('未找到 ducc CLI')
    with tempfile.TemporaryDirectory() as wd:
        proc = subprocess.run([binary,'-p','--model',model,'--tools','','--strict-mcp-config',
                               '--disable-slash-commands','--no-session-persistence','--output-format','json'],
                              input=prompt(plan), text=True, capture_output=True, timeout=180, cwd=wd)
    if proc.returncode:
        raise ValueError('DUCC 请求失败，未写入练习文本')
    write(folder/'text.json', parse_gemini(proc.stdout, plan['count']))


def synthesize(support, folder, flags, reference, path):
    if not flags.get('voice'):
        raise ValueError('请先在设置允许本人音色合成')
    rows, _ = reviewed(support)
    training, _ = split(rows)
    ref = next((r for r in training if r['id']==reference and r.get('audioAligned') is True and r.get('audio')), None)
    if not ref:
        raise ValueError('参考录音必须来自训练区，并已核对音频与发送稿')
    model = read(path/'config.json', {}) if path and path.is_dir() else {}
    family = str(model.get('model_type') or model.get('architecture') or '').lower()
    if family not in {'voxcpm2','qwen3_tts'} or (family=='qwen3_tts' and model.get('tts_model_type')!='base'):
        raise ValueError('请提供已下载的本地 VoxCPM2 或 Qwen3-TTS Base 目录')
    pairs = read(folder/'text.json', [])
    if not pairs:
        raise ValueError('请先生成并阅读练习文本')
    target = folder/'synthetic'
    if target.exists():
        raise ValueError('这批音频已经生成')
    import soundfile as sf
    ref_info=sf.info(ref['audio'])
    if not 2 <= ref_info.duration <= 20:
        raise ValueError('请选择 2–20 秒的本人干净短录音')
    os.environ['HF_HUB_OFFLINE']='1'
    os.environ['TRANSFORMERS_OFFLINE']='1'
    from mlx_audio.tts.generate import generate_audio
    from mlx_audio.tts.utils import load_model
    with (support/'inference.lock').open('a') as lock, tempfile.TemporaryDirectory(dir=folder) as tmp:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('本机模型在使用中，请结束当前推理后重试') from None
        tts = load_model(str(path))
        stage = Path(tmp)/'audio'
        stage.mkdir()
        for i, pair in enumerate(pairs):
            prefix = f'clip-{i+1:02}'
            generate_audio(text=pair['spoken'],model=tts,ref_audio=ref['audio'],ref_text=ref['reviewedFinal'],
                           output_path=str(stage),file_prefix=prefix,audio_format='wav',join_audio=True,play=False)
            if sf.info(stage/(prefix+'.wav')).duration <= 0:
                raise ValueError('合成没有返回音频')
        write(stage/'manifest.json', {'synthetic':True, 'status':'needs_review','reference':reference,'model':path.name,'pairs':pairs})
        stage.rename(target)



def accept_clip(support, folder, plan, index, aligned, purpose):
    """Review the generated audio locally. Obtain the raw text from an actual ASR pass."""
    import soundfile as sf
    target=folder/'synthetic'
    meta=read(target/'manifest.json',{})
    pairs=meta.get('pairs',[])
    if not 1 <= index <= len(pairs):
        raise ValueError('这组音频不存在')
    audio=target/f'clip-{index:02}.wav'
    if not audio.is_file():
        raise ValueError('合成音频不存在')
    pair=pairs[index-1]
    print('请先试听 '+str(audio))
    print(json.dumps(pair,ensure_ascii=False))
    key=f'{folder.name}/{index}'
    if input('确认这条发音及整理目标正确，输入 '+key+'：').strip()!=key:
        raise ValueError('没有接纳此音频')
    with (support/'inference.lock').open('a') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('本机推理占用中，请结束当前推理后重试') from None
        from mlx_audio.stt import load
        from mlx_audio.stt.utils import load_audio
        config=read(support/'config.json')
        model=load(config['asrModel'])
        # Use exactly the signal the recognizer hears. Store a mono 16 kHz
        # WAV for ASR training even when the synthesizer produced 24/48 kHz.
        import numpy as np
        pcm=np.asarray(load_audio(str(audio),sr=16000))
        if pcm.ndim!=1 or len(pcm)<4800:raise ValueError('音频不适用于识别')
        raw=model.generate(pcm,temperature=0,repetition_penalty=1.05,max_tokens=768).text.strip()
        if not raw:raise ValueError('实际语音识别没有返回文字')
        dest=target/f'clip-{index:02}-16k.wav'
        with tempfile.TemporaryDirectory(dir=target) as tmp:
            converted=Path(tmp)/'converted.wav'
            sf.write(converted,pcm,16000)
            os.replace(converted,dest)
    write(target/f'clip-{index:02}-review.json',dict(id=f'practice-{folder.name}-{index}',source=plan['source'],
          purpose=purpose,raw=raw,reviewedFinal=pair['cleaned'],audioAligned=aligned,audio=dest.name,synthetic=True))


def training_practice(support, train, held):
    """Admitted practice is at most a fifth of training. Real evaluation never calls this function."""
    source_ids={r['id'] for r in train}
    seen={re.sub(r'[\W_]+','',r['raw'].casefold()) for r in train+held}
    withheld={re.sub(r'[\W_]+','',r['reviewedFinal'].casefold()) for r in held}
    rows=[]
    for f in sorted((support/'learning'/'practice').glob('*/synthetic/clip-*-review.json')):
        if len(rows)>=len(train)//4: break
        try:
            row=read(f,{})
            expected=f.stem.replace('-review','')+'-16k.wav'
            if (row.get('purpose')!='train' or row.get('source') not in source_ids or row.get('synthetic') is not True
                    or row.get('audio')!=expected or not (f.parent/expected).is_file()):continue
            raw=re.sub(r'[\W_]+','',row['raw'].casefold())
            target=re.sub(r'[\W_]+','',row['reviewedFinal'].casefold())
            if not raw or raw in seen or raw in withheld or target in withheld:continue
            rows.append({**row,'audio':str(f.parent/expected)});seen.add(raw)
        except (OSError,ValueError,KeyError,TypeError):
            continue
    return rows

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--support', type=Path, required=True)
    sub = parser.add_subparsers(dest='action',required=True)
    propose_cmd = sub.add_parser('propose')
    propose_cmd.add_argument('--category',choices=CATEGORIES,required=True)
    propose_cmd.add_argument('--public-topic',required=True)
    propose_cmd.add_argument('--source-id',required=True)
    propose_cmd.add_argument('--count',type=int,default=4)
    for action in ('show','approve','generate-text','synthesize','accept-clip'):
        command=sub.add_parser(action)
        command.add_argument('id')
        if action=='generate-text': command.add_argument('--model',required=True)
        if action=='accept-clip':
            command.add_argument('--index',type=int,required=True)
            command.add_argument('--audio-aligned',action='store_true',help='已试听并确认整理目标与语音逐句对应')
            command.add_argument('--set',choices=('train','challenge'),default='train')
        if action=='synthesize':
            command.add_argument('--reference-id',required=True)
            command.add_argument('--model-path',type=Path,required=True)
            command.add_argument('--my-voice',action='store_true',required=True,help='确认参考录音只有本人声音')
    args=parser.parse_args()
    os.umask(0o077)
    support=args.support.resolve()
    flags=read(support/'learning-settings.json',{})
    if not flags.get('retain'):
        raise ValueError('请先开启学习资料留存')
    root=support/'learning'/'practice'
    if args.action=='propose':
        print(propose(support,args.category,args.public_topic,args.source_id,args.count))
        return
    folder,plan=checked_plan(root,args.id)
    if args.action in ('approve','show'):
        print('将提交给 DUCC Gemini 的全部内容\n'+prompt(plan))
        if args.action=='approve':
            if input('确认这项已发现的问题和以上公开主题，输入提案编号批准本批：').strip()!=args.id:
                raise ValueError('没有批准本批')
            write(folder/'approved.json',{'id':args.id,'prompt_hash':fingerprint(prompt(plan))})
        return
    with (folder/'job.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        if read(folder/'approved.json',{}) != {'id':args.id,'prompt_hash':fingerprint(prompt(plan))}:
            raise ValueError('本批尚未获得用户批准')
        if args.action=='generate-text': generate(folder,plan,args.model)
        elif args.action=='accept-clip':
            accept_clip(support,folder,plan,args.index,args.audio_aligned,args.set)
        else: synthesize(support,folder,flags,args.reference_id,args.model_path.resolve())
    print('结果保存在本机 '+str(folder))


if __name__=='__main__':
    try: main()
    except (ValueError,OSError,RuntimeError,EOFError,subprocess.TimeoutExpired) as ex:
        print(str(ex))
        raise SystemExit(1)
