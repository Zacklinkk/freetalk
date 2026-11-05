#!/usr/bin/env python3
"""Reproducible synthetic-text smoke evaluation, separate from real meeting quality.

Use --provider cloud with FREETALK_EVAL_API_KEY to generate a reference candidate.
Never assumes model output is human ground truth. No private history is read.
"""
import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'python'))
from meeting_models import local_generator, cloud_generator
from meeting_pipeline import validate_segments
from meeting_summary import summarize


CHECKS = {
    'final_sample_count': r'12个',
    'keep_all_logs': r'所有日志.{0,8}保留|保留.{0,6}所有日志',
    'release_not_committed': r'不能承诺.{0,8}发布|发布日期.{0,8}(?:未|不|还没)',
    'named_owner_and_due': r'小王.{0,6}周四.{0,8}提交.{0,6}报告',
    'release_condition': r'只有回归.{0,8}通过.{0,12}才.{0,12}发布',
    'budget': r'(?:上限|预算).{0,8}3万元',
    'sft_version': r'先.{0,5}验证第1版SFT',
    'proper_name': r'如流知识库',
    'unassigned_owner': r'云端费用.{0,12}负责人.{0,8}(?:未|不|还没)',
}


def metrics(minutes, tree, segments):
    text = '\n'.join(f['text'] for f in minutes['facts'])
    by_id = {s['id']: s for s in segments}
    refs = [e for f in minutes['facts'] for e in f['evidence']]
    valid = sum(e['segment_id'] in by_id and e['quote'] in by_id[e['segment_id']]['text'] for e in refs)
    leaves = []
    def visit(node):
        if not node.get('children'):
            leaves.extend(node.get('fact_ids', []))
        for child in node.get('children', []):
            visit(child)
    visit(tree)
    facts = {f['id'] for f in minutes['facts']}
    return {'source_reference_validity': valid / max(1,len(refs)),
            'mindmap_fact_coverage': len(set(leaves)&facts) / max(1,len(facts)),
            'duplicate_leaf_count': len(leaves)-len(set(leaves)),
            'structured_checks': {
                'owner_and_due_fields': any(f['kind']=='action' and f.get('owner')=='小王' and f.get('due')=='周四' for f in minutes['facts']),
                'release_condition_classified': any(f['kind']=='constraint' and re.search(CHECKS['release_condition'],f['text']) for f in minutes['facts']),
                'proposal_not_committed': not any(f['kind']=='decision' and '建议周五' in f['text'] for f in minutes['facts']),
                'quoted_command_not_action': not any(f['kind']=='action' and '删除' in f['text'] and '日志' in f['text'] for f in minutes['facts']),
                'no_extractive_fallback': not any(f.get('topic')=='待整理原文' for f in minutes['facts']),
            },
            'sample_checks': {key: bool(re.search(pattern, text)) for key, pattern in CHECKS.items()},
            'warning_count': len(minutes['warnings']),
            'note': 'Synthetic regression checks only; regex coverage is not a semantic accuracy score or real-meeting benchmark.'}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--provider', choices=['local','cloud'], default='local')
    p.add_argument('--config', type=Path)
    p.add_argument('--base-url'); p.add_argument('--model')
    p.add_argument('--sample', type=Path, default=Path(__file__).resolve().parents[1]/'examples/meetings/sample.json')
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    sample = json.loads(args.sample.read_text())
    if sample.get('synthetic') is not True:
        raise ValueError('This evaluator accepts explicitly synthetic fixtures only')
    segments = validate_segments(sample['segments'])
    if args.provider == 'local':
        if not args.config:
            p.error('--config is required for local evaluation')
        config = json.loads(args.config.read_text())
        from mlx_lm import load
        model, tokenizer = load(config['cleanupModel'],tokenizer_config={'trust_remote_code':False})
        generate = local_generator(model,tokenizer); model_name = Path(config['cleanupModel']).name
    else:
        generate = cloud_generator(args.base_url or '',args.model or '',os.environ.get('FREETALK_EVAL_API_KEY',''))
        model_name = args.model
    start = time.monotonic()
    minutes, tree = summarize(segments,generate,title=sample.get('title','合成会议'))
    result = {'model':model_name,'provider':args.provider,'seconds':round(time.monotonic()-start,3),
              'synthetic':True,'human_verified_ground_truth':False,'metrics':metrics(minutes,tree,segments),'minutes':minutes,'mindmap':tree}
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ('model','seconds','metrics')},ensure_ascii=False,indent=2))


if __name__ == '__main__':
    main()
