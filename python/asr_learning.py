"""A local decoder-only Qwen3-ASR adapter, supervised by aligned final sent text."""
import os
from pathlib import Path
import re

import personal_learning as learn


PARAMS = dict(rank=8, scale=16., dropout=0., keys=['self_attn.q_proj', 'self_attn.v_proj'])


def audio_rows(rows):
    import soundfile as sf
    approved = []
    for row in rows:
        if not row.get('audioAligned') or not row.get('audio'):
            continue
        try:
            info = sf.info(row['audio'])
        except (OSError,RuntimeError):
            continue
        if info.channels == 1 and info.samplerate == 16000 and .3 <= info.duration <= 20:
            approved.append(row)
    return approved


def attach(model, folder=None):
    from mlx_lm.tuner.utils import linear_to_lora_layers
    model.freeze()
    linear_to_lora_layers(model.model, 4, PARAMS)
    if folder:
        model.load_weights(str(folder/'adapters.safetensors'), strict=False)


def step_inputs(model, row):
    import mlx.core as mx
    import soundfile as sf
    audio, _ = sf.read(row['audio'], dtype='float32')
    features, mask, count = model._preprocess_audio(audio)
    language = 'Chinese' if re.search(r'[\u3400-\u9fff]', row['reviewedFinal']) else 'English'
    prompt = model._build_prompt(count, language)
    target = model._tokenizer.encode(row['reviewedFinal'], add_special_tokens=False) + [model._tokenizer.convert_tokens_to_ids('<|im_end|>')]
    ids = mx.concatenate([prompt, mx.array([target[:-1]])], axis=1)
    # Freeze the acoustic encoder and train on transcript tokens only.
    acoustic = model.get_audio_features(features,mask)
    embeds = mx.stop_gradient(model._build_inputs_embeds(ids,acoustic))
    mx.eval(embeds)
    return embeds, prompt.shape[1]-1, mx.array([target])


def train_steps(model, rows, folder, max_steps=None):
    import mlx.core as mx
    import mlx.nn as nn
    import mlx.optimizers as optim
    from mlx.utils import tree_flatten
    # mlx-audio wraps the speech model; the optimizer needs its actual nn.Module.
    model = getattr(model, "_model", model)
    mx.random.seed(29)
    weights=folder/'adapters.safetensors'
    attach(model, folder if weights.exists() else None)
    step=int(mx.load(str(weights),return_metadata=True)[1]['step']) if weights.exists() else 0
    opt=optim.SGD(learning_rate=.0001)
    def loss(m, embeds, first, target):
        hidden=m.model(inputs_embeds=embeds)[:,first:,:]
        logits=m.lm_head(hidden) if m.lm_head is not None else m.model.embed_tokens.as_linear(hidden)
        return nn.losses.cross_entropy(logits.astype(mx.float32),target,reduction='mean')
    gradient=nn.value_and_grad(model,loss)
    total=min(len(rows)*2,64) if max_steps is None else max_steps
    last_loss=None
    for i in range(step,total):
        learn.check_pause()
        value, grads=gradient(model,*step_inputs(model,rows[i % len(rows)]))
        opt.update(model,grads)
        saved=dict(tree_flatten(model.trainable_parameters()))
        mx.eval(saved,value)
        last_loss=float(value.item())
        if not saved or not all(k.endswith(('lora_a','lora_b')) for k in saved):
            raise ValueError('语音识别训练范围异常，未保存')
        tmp=folder/'next.safetensors'
        mx.save_safetensors(str(tmp),saved,metadata={'step':str(i+1)})
        os.replace(tmp,weights)
    return total,last_loss


def evaluate(model, rows):
    import soundfile as sf
    from cleanup_eval import flat
    scores=[]
    for r in rows:
        learn.check_pause()
        audio,_=sf.read(r['audio'],dtype='float32')
        predicted=flat(model.generate(audio,language=None,temperature=0,repetition_penalty=1.05,
                                      max_tokens=min(1024,max(128,int(len(audio)/16000*22)+64))).text)
        target=flat(r['reviewedFinal'])
        errors,deleted=learn.quality(predicted,target)
        scores.append(dict(id=r['id'],real=True,chars=len(target),errors=errors,deletions=deleted,exact=target==predicted))
    return scores


def fit(support, config):
    from mlx_audio.stt import load
    import mlx.core as mx
    import gc
    rows,_=learn.reviewed(support)
    real_train,real_test=learn.split(rows)
    train,test=map(audio_rows,(real_train,real_test))
    if len(train)<learn.MIN_TRAIN or len(test)<learn.MIN_TEST:
        return f'语音识别需要跨日期且与录音一致的短发送稿，训练 {len(train)}/8，保留 {len(test)}/4。'
    from learning_augmentation import training_practice
    train += audio_rows(training_practice(support,real_train,real_test))[:len(train)//4]
    base=learn.model_key(config,'asrModel')
    stat=lambda r: (r['id'],r['reviewedFinal'],Path(r['audio']).stat().st_mtime_ns)
    key=learn.fingerprint(['asr-v1',base,PARAMS,[stat(r) for r in train],[stat(r) for r in test]])[:24]
    folder=learn.candidate_dir(support,key);folder.mkdir(parents=True,exist_ok=True,mode=0o700)
    report=learn.read(folder/'report.json')
    if not report:
        mx.set_memory_limit(7*2**30);mx.set_cache_limit(256*2**20)
        model=load(config['asrModel'])
        before=evaluate(model,test)
        steps,_=train_steps(model,train,folder)
        del model
        gc.collect();mx.clear_cache();learn.check_pause()
        candidate=load(config['asrModel']);attach(candidate,folder)
        after=evaluate(candidate,test)
        report=dict(id=key,lane='asr',base=base,steps=steps,baseline=before,candidate=after,passed=learn.acceptance(before,after))
        learn.write(folder/'report.json',report)
    learn.write(support/'learning'/'latest-asr.json',{'id':key})
    return 'ASR 候选通过文字验收，可以手动试用。' if report['passed'] else 'ASR 候选未通过文字验收，继续使用基础模型。'
