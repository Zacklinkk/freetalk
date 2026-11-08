#!/usr/bin/env python3
"""Evaluate an explicit local audio file, without reading personal histories.

Run with the configured MLX Python after quitting freetalk. No downloads or
uploads. Reference speaker turns are optional JSON rows: start/end/speaker.
Frame DER includes overlap, uses a 20 ms grid, no collar, and optimal assignment.
It is not comparable to leaderboards with different protocols. No CER/WER is
reported without an aligned verbatim reference.
"""
import argparse
import hashlib
import json
import sys
import time
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'python'))


def diarization_metrics(reference, hypothesis, duration):
    import numpy as np
    from scipy.optimize import linear_sum_assignment
    labels=lambda rows:sorted({r['speaker'] for r in rows})
    ts=np.arange(.01,duration,.02)
    matrix=lambda rows,ids:np.array([[any(r['speaker']==s and r['start']<=t<r['end'] for r in rows) for s in ids] for t in ts],dtype=bool).reshape(len(ts),len(ids))
    R,H=matrix(reference,labels(reference)),matrix(hypothesis,labels(hypothesis))
    a,b=linear_sum_assignment(-(R.T.astype(int)@H.astype(int)))
    correct=np.zeros(len(ts),dtype=int)
    for i,j in zip(a,b):correct+=(R[:,i]&H[:,j])
    ref,hyp=R.sum(1),H.sum(1);overlap=ref>1
    return dict(protocol='20 ms frames; no collar; overlap included; optimal speaker mapping',
                DER=float((np.maximum(ref-hyp,0).sum()+np.maximum(hyp-ref,0).sum()+(np.minimum(ref,hyp)-correct).sum())/max(1,ref.sum())),
                reference_speakers=R.shape[1],predicted_speakers=H.shape[1],
                overlap_seconds=float(overlap.sum()*.02),
                overlap_recall=float((overlap&(hyp>1)).sum()/overlap.sum()) if overlap.any() else None)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--config',type=Path,required=True);p.add_argument('--audio',type=Path,required=True)
    p.add_argument('--reference-turns',type=Path);p.add_argument('--diarization',action='store_true')
    p.add_argument('--terms',default='');p.add_argument('--output',type=Path,required=True)
    p.add_argument('--minimum-seconds',type=float,default=4)
    args=p.parse_args()
    import numpy as np,soundfile as sf,mlx.core as mx
    from engine import Engine
    from meeting_models import diarize
    from meeting_pipeline import intervals
    audio,sr=sf.read(args.audio,dtype='float32')
    if sr!=16000 or audio.ndim!=1:raise SystemExit('Use an explicit 16 kHz mono WAV clip; document the original channel and times.')
    cfg=json.loads(args.config.read_text());cfg['inferenceLockPath']=str(args.config.parent/'inference.lock')
    engine=Engine(cfg);duration=len(audio)/sr;start=time.monotonic()
    turns=diarize(str(args.audio),cfg.get('meetingDiarizationModel'),lambda **event:None) if args.diarization else []
    diarization_seconds=time.monotonic()-start;rows=[];start=time.monotonic();calls=0
    for a,b,speakers in intervals(duration,turns,minimum=args.minimum_seconds):
        samples=audio[round(a*sr):round(b*sr)]
        if len(samples)<1600 or float(np.sqrt(np.mean(samples*samples)))<.0015:continue
        t=time.monotonic();calls+=1
        r=engine.asr.generate(samples,language=None,hotwords=[s.strip() for s in args.terms.split(',') if s.strip()][:48],temperature=0,repetition_penalty=1.05,max_tokens=min(1024,max(128,int((b-a)*22)+64)))
        mx.synchronize();rows.append(dict(start=a,end=b,speakers=speakers,text=r.text,seconds=round(time.monotonic()-t,3)))
    result=dict(audio_sha256=hashlib.sha256(args.audio.read_bytes()).hexdigest(),duration=duration,
                asr_model=Path(cfg['asrModel']).name,diarization_seconds=diarization_seconds,
                asr_seconds=time.monotonic()-start,asr_calls=calls,rows=rows,turns=turns)
    if args.reference_turns:result['diarization']=diarization_metrics(json.loads(args.reference_turns.read_text()),turns,duration)
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in result.items() if k not in ('rows','turns')},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
