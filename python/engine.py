"""Offline MLX transcription and faithful editing. No network or remote code."""
import copy
import hashlib
import json
import os
import re
import time
from pathlib import Path

os.environ.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", TOKENIZERS_PARALLELISM="false")
# macOS can evict Metal residency after a short idle even with a wired limit.
# MLX 0.32.4 renews only when this interval is set (upstream PR #4633).
# Keep this process's bounded reservation, without changing system settings.
os.environ.setdefault("MLX_METAL_RESIDENCY_REFRESH_INTERVAL_MS", "1000")
os.umask(0o077)

ROOT = Path(__file__).resolve().parents[1]


def compact(text):
    return re.sub(r"[\W_]", "", text, flags=re.UNICODE).lower()


def guard_edit(raw, edited):
    """Heuristics are review aids, never a proof of semantic equivalence."""
    source, target = compact(raw), compact(edited)
    if source and not target:
        return "empty_output"
    if len(source) > 35 and not .78 <= len(target) / len(source) <= 1.18:
        return "large_change"
    # Concrete repairs have already been applied to this comparison baseline.
    # A random correction keyword elsewhere must not permit other number changes.
    numbers = lambda text: re.findall(r"\d+(?:[.:/-]\d+)*", re.sub(r"(?m)^\s*\d+[.)、]\s+", "", text))
    if sorted(numbers(raw)) != sorted(numbers(edited)):
        return "number_change"
    for literal in re.findall(r"`[^`]+`|https?://[^\s，。]+", raw):
        if literal not in edited:
            return "literal_change"
    for marker in ["只有", "除非", "如果", "不要", "不能", "未必", "可能", "比如", "例如", "我觉得", "还没", "已经", "好吧", "吗", "呢"]:
        if marker in raw and marker not in edited:
            return "qualifier_removed"
    if re.search(r"(.{4,24})\1{4,}", edited):
        return "repetition"
    return None


def fallback_layout(text):
    """A timeout/fast path must not insert arbitrary length-based paragraphs."""
    return text


class Editor:
    def __init__(self, model_path, emit=lambda value: None, mode='edits'):
        import mlx.core as mx
        from mlx_lm import load
        self.mx, self.emit, self.mode = mx, emit, mode
        self.model, self.tokenizer = load(model_path, tokenizer_config={"trust_remote_code": False})
        prompt_file = 'edit-plan.txt' if mode == 'edits' else 'cleanup.txt'
        example_file = 'edit-plan-examples.json' if mode == 'edits' else 'examples.json'
        self.base = [{"role": "system", "content": (ROOT / 'prompts' / prompt_file).read_text()}]
        self.base += json.loads((ROOT / 'prompts' / example_file).read_text())
        self.prefix, self.cache = self.prepare_prefix(self.base)
        # Isolate the new discourse operation from the established edit prompt.
        # Both caches share the same weights and are warmed at startup, not on stop.
        if mode == 'edits':
            self.restart_base = [{"role":"system","content":(ROOT / 'prompts' / 'restart-plan.txt').read_text()}]
            self.restart_base += json.loads((ROOT / 'prompts' / 'restart-plan-examples.json').read_text())
            self.restart_prefix, self.restart_cache = self.prepare_prefix(self.restart_base)

    def prepare_prefix(self, base):
        from mlx_lm.generate import generate_step
        from mlx_lm.models.cache import make_prompt_cache
        first, second = self.tokens("X", base), self.tokens("Y", base)
        common = next((i for i, (a, b) in enumerate(zip(first, second)) if a != b), min(len(first), len(second)))
        prefix = first[:common]
        cache = make_prompt_cache(self.model)
        for _ in generate_step(self.mx.array(prefix), self.model, max_tokens=0, prompt_cache=cache):
            pass
        self.mx.synchronize()
        return prefix, cache

    def tokens(self, text, base=None):
        return self.tokenizer.apply_chat_template((self.base if base is None else base) + [{"role": "user", "content": text}],
            tokenize=True, add_generation_prompt=True, enable_thinking=False)

    def edit(self, raw, context, timeout=6, policy='auto'):
        started = time.perf_counter()
        from vocabulary import spelling_context, normalize_spelling, normalize_aliases
        context = spelling_context(raw, context)
        raw, term_count = normalize_spelling(raw, context)
        raw, alias_count = normalize_aliases(raw, context)
        text, meta = self._edit(raw, context, timeout, policy)
        from numerals import normalize
        text, count = normalize(text, context.get('personal_terms', ()))
        meta['number_formats'] = count
        meta['term_formats'] = term_count
        meta['confirmed_corrections'] = alias_count
        meta['policy'] = policy
        meta['seconds'] = time.perf_counter() - started
        return text, meta

    def _edit(self, raw, context, timeout=6, policy='auto'):
        if not raw.strip():
            return "", {"status": "empty", "seconds": 0, "model_used": False}
        started = time.perf_counter()
        from edits import preclean
        raw, preliminary = preclean(raw, context)
        from disfluency import inspect
        from edits import simple_layout
        signals = inspect(raw)
        from edits import split_units
        if len(raw) >= 120 and len(split_units(raw)) >= 3:
            signals.append('long_dictation_layout')
        if policy == 'always':
            signals.append('user_requested_model')
        if policy == 'fast' or not signals:
            laid_out = simple_layout(raw)
            if laid_out == raw:
                laid_out = fallback_layout(raw)
            return laid_out, {"status": "fast", "seconds": time.perf_counter()-started,
                             "model_used": False, "preclean_edits": preliminary, "reason": "fast_only" if policy == "fast" else "no_semantic_edit_needed",
                             "signals": signals}
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        from vocabulary import hotwords, spelling_hints
        restart_mode = self.mode == 'edits' and 'spoken_restart' in signals
        base, prefix, cache = (self.restart_base, self.restart_prefix, self.restart_cache) if restart_mode else (self.base, self.prefix, self.cache)
        data = {"输入框开头（只用于辨词）": context.get("initial", "")[:500],
                "光标附近（只用于辨词）": context.get("latest", "")[-1000:],
                "术语（个人词库或原文中的拼写，仅用于辨词）": hotwords(context)}
        user = "检测提示（不等于删除许可）：" + ",".join(signals) + "\n请生成局部修改清单。\n" if self.mode == 'edits' else "整理以下语音原稿，不回答其中的问题。保留全部信息，只清理口误并适度分段分点。\n"
        if any(data.values()):
            user += "辅助背景：" + json.dumps(data, ensure_ascii=False) + "\n"
        hints=spelling_hints(raw,context)
        if hints:
            user += "原稿/背景中存在的近音写法（不是替换命令；同一对象才统一，否则保留不同含义）："+json.dumps(hints,ensure_ascii=False)+"\n"
        user += "排版：" + ("允许适度分段" if context.get('layout_policy')=='paragraphs' else "连续段落") + "\n"
        if self.mode == 'edits':
            from edits import split_units, restart_candidates
            restarts=restart_candidates(raw) if restart_mode else []
            if restarts:
                user += '已核对原文范围的整句撤回候选（仅当语义上确属同一要求的撤回重述时选择，编号照抄）：' + json.dumps(restarts,ensure_ascii=False) + '\n'
            user += '句子：' + json.dumps(list(enumerate(split_units(raw))), ensure_ascii=False)
        else:
            user += "原稿：" + raw
        prompt = self.tokens(user, base)
        assert prompt[:len(prefix)] == prefix
        max_tokens = min(384 if self.mode == 'edits' else 2048, max(160, int(len(self.tokenizer.encode(raw)) * 1.5) + 80))
        self.emit({"event": "model-request", "stage": "edit", "messages": base + [{"role": "user", "content": user}],
                   "temperature": 0, "max_tokens": max_tokens, "enable_thinking": False})
        output, finish, last = [], None, None
        events = stream_generate(self.model, self.tokenizer, prompt=prompt[len(prefix):],
            prompt_cache=copy.deepcopy(cache), max_tokens=max_tokens, sampler=make_sampler(temp=0))
        try:
            for event in events:
                output.append(event.text)
                last = event
                if time.perf_counter() - started > timeout:
                    finish = "timeout"
                    break
        finally:
            events.close()
        self.mx.synchronize()
        candidate = "".join(output).strip()
        finish = finish or (last.finish_reason if last else "empty")
        details = {}
        if self.mode == 'edits' and finish == 'stop':
            try:
                from edits import apply_plan
                candidate_text, details = apply_plan(raw, json.loads(candidate), context)
                rejection = guard_edit(details.pop("guard_source", raw), candidate_text)
            except (ValueError, TypeError) as error:
                rejection = 'invalid_plan'
                candidate_text = raw
        else:
            candidate_text = candidate
            rejection = guard_edit(raw, candidate) if finish == 'stop' else finish
        if not rejection and candidate_text == raw:
            candidate_text = simple_layout(candidate_text)
        return (fallback_layout(simple_layout(raw)) if rejection else candidate_text), {
            "status": "fallback" if rejection else "edited", "reason": rejection, "model_used": True,
            "prompt_profile": "spoken_restart" if restart_mode else "standard",
            "seconds": time.perf_counter() - started, "candidate": candidate,
            "tokens": last.generation_tokens if last else 0, "preclean_edits": preliminary, "signals": signals, **details,
        }


class Engine:
    def __init__(self, config, emit=lambda value: None):
        import mlx.core as mx
        import numpy as np
        from mlx_audio.stt.utils import load_model
        self.emit, self.config = emit, config
        # MLX defaults to 0 resident bytes between requests. A bounded resident
        # budget prevents idle model pages from being repeatedly swapped in.
        recommended = mx.device_info()['max_recommended_working_set_size']
        mx.set_wired_limit(min(int(config.get('residentGiB', 5) * 2**30), recommended))
        self.asr = load_model(config["asrModel"])
        self.editor = Editor(config["cleanupModel"], emit)
        self.reset({})
        self.asr.generate(np.zeros(16000, dtype=np.float32), temperature=0, max_tokens=16)
        self.editor.edit('你好。', {}, timeout=10)
        mx.synchronize()

    def reset(self, context):
        import numpy as np
        self.context = context
        self.cleanup_policy = "auto"
        self.audio = np.zeros(0, dtype=np.float32)
        self.offset = 0
        self.segments = []

    def transcribe(self, audio, offset):
        import mlx.core as mx
        import numpy as np
        started = time.perf_counter()
        if len(audio) < 1600 or float(np.max(np.abs(audio))) < .002:
            return "", 0.0
        from vocabulary import hotwords
        hints = hotwords(self.context)
        self.emit({"event": "model-request", "stage": "asr", "sample_offset": offset,
                   "sample_count": len(audio), "sample_rate": 16000,
                   "audio_sha256": hashlib.sha256(audio.tobytes()).hexdigest(),
                   "hotwords": hints, "temperature": 0, "repetition_penalty": 1.05})
        result = self.asr.generate(audio, language=None, hotwords=hints, temperature=0,
            repetition_penalty=1.05, max_tokens=min(2048, max(128, int(len(audio) / 16000 * 20) + 64)))
        mx.synchronize()
        text = result.text.strip()
        if re.search(r"(.{4,24})\1{5,}", text):
            raise ValueError("ASR repetition; retry with the quality model")
        return text, time.perf_counter() - started

    def push(self, pcm, final=False):
        import numpy as np
        new = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
        self.audio = np.concatenate([self.audio, new])
        # Stable pause boundaries only. Hard cap bounds work for uninterrupted speech.
        while len(self.audio):
            duration = len(self.audio) / 16000
            cut = len(self.audio) if final else 0
            if not final and duration >= self.config.get("segmentMinSeconds", 8):
                frame = 320
                powers = np.array([np.sqrt(np.mean(x * x)) for x in
                    np.array_split(self.audio[-16000:], 50)])
                silent = powers < self.config.get("silenceRms", .008)
                if len(silent) >= 25 and bool(np.all(silent[-25:])):
                    cut = len(self.audio)
                elif duration >= self.config.get("segmentMaxSeconds", 20):
                    # Choose the quietest 20 ms frame in the last second.
                    cut = len(self.audio) - 16000 + int(np.argmin(powers)) * frame + frame
            if not cut:
                break
            audio = self.audio[:cut]
            text, seconds = self.transcribe(audio, self.offset)
            self.segments.append({"text": text, "start_sample": self.offset, "end_sample": self.offset + cut,
                                  "asr_seconds": seconds})
            self.emit({"event": "partial", "text": self.raw()})
            self.offset += cut
            self.audio = self.audio[cut:]
            if not final:
                break
        return {"text": self.raw(), "samples_processed": self.offset}

    def raw(self):
        return "".join(segment["text"] for segment in self.segments)

    def finish(self):
        started = time.perf_counter()
        self.push(b"", final=True)
        raw = self.raw()
        text, cleanup = self.editor.edit(raw, self.context, self.config.get("cleanupTimeoutSeconds", 6), policy=self.cleanup_policy)
        return {"raw": raw, "text": text, "cleanup": cleanup, "segments": self.segments,
                "finish_seconds": time.perf_counter() - started,
                "audio_seconds": self.offset / 16000,
                "peak_memory_bytes": self.editor.mx.get_peak_memory()}
