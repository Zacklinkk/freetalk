"""Translation input: dictate in one language, insert another.

The dictation is cleaned first, with the same rules and checks as normal
input, then translated: by the fast cloud model when 云端模型 → 翻译输入 is on,
otherwise by the local editor model. A translation must keep every number,
link and code span of its source; a reply that does not is refused rather
than inserted. The prompt is prompts/translation.txt.
"""
import re
import time

LANGUAGES = {'en': 'English', 'zh': '简体中文', 'ja': '日本語', 'ko': '한국어', 'fr': 'Français', 'de': 'Deutsch', 'es': 'Español'}
CJK = r'[一-鿿]'


def target_language(text, setting):
    """The language code to translate into. "auto": Chinese to English, anything else to Chinese."""
    if setting in LANGUAGES:
        return setting
    letters = len(re.findall(r'[A-Za-z一-鿿぀-ヿ가-힯]', text))
    return 'en' if letters and len(re.findall(CJK, text)) / letters >= .3 else 'zh'


def messages(text, target):
    from prompt_files import source
    return [{'role': 'system', 'content': source('translation.txt')},
            {'role': 'user', 'content': f'目标语言：{LANGUAGES[target]}\n原文：\n{text}'}]


def unwrap(reply):
    """The translation without a label or fence a model sometimes adds."""
    text = reply.strip()
    text = re.sub(r'^```[a-zA-Z]*\n(.*)\n```$', r'\1', text, flags=re.S).strip()
    return re.sub(r'^(?:译文|翻译|Translation)\s*[:：]\s*', '', text).strip()


def problem(source, translated, target):
    """Why `translated` must not be inserted, or None."""
    if not translated.strip():
        return 'empty'
    if len(translated) > 5 * len(source) + 40 or len(translated) * 5 + 20 < len(source):
        return 'length'
    han_source, han = len(re.findall(CJK, source)), len(re.findall(CJK, translated))
    if target == 'zh' and not han and re.search(r'[A-Za-z]{3}', source) and re.search(r'[A-Za-z]{3}', translated):
        return 'untranslated'
    # Into a language without Chinese characters, most of them must be gone.
    if target not in ('zh', 'ja') and han_source >= 4 and han >= han_source / 2:
        return 'untranslated'
    # A month number may become a month name (11月 → November).
    numbers = [m[0] for m in re.finditer(r'\d+(?:\.\d+)*', source) if not (target not in ('zh', 'ja') and source[m.end():m.end() + 1] == '月')]
    found = re.findall(r'\d+(?:\.\d+)*', translated)
    if any(n not in found for n in numbers):
        return 'number_changed'
    for literal in re.findall(r'`[^`]+`|https?://[^\s，。]+|[\w.+-]+@[\w-]+\.[\w.]+', source):
        if literal not in translated:
            return 'literal_changed'
    return None


def translate(text, target, cloud=None, local=None, timeout=20):
    """Return (translation or None, metadata). Cloud first when configured, local otherwise or on failure.

    `cloud(messages, max_tokens, timeout)` is a cloud_client complete function;
    `local(messages, max_tokens, timeout)` generates with the local model.
    """
    from cloud_client import CloudUnavailable
    started = time.perf_counter()
    target = target_language(text, target)
    meta = {'target': target}
    if not text.strip():
        return '', {**meta, 'status': 'empty', 'seconds': 0}
    prompt = messages(text, target)
    max_tokens = min(2048, 3 * len(text) + 64)
    for engine, complete in (('cloud', cloud), ('local', local)):
        if complete is None:
            continue
        try:
            reply = complete(prompt, max_tokens, timeout)
        except CloudUnavailable as error:
            meta['cloud_fallback'] = error.reason
            continue
        except (TimeoutError, ValueError):
            meta[engine + '_failure'] = 'timeout'
            continue
        translated = unwrap(reply)
        reason = problem(text, translated, target)
        if reason is None:
            return translated, {**meta, 'status': 'translated', 'engine': engine, 'seconds': round(time.perf_counter() - started, 2)}
        meta[engine + '_failure'] = reason
    return None, {**meta, 'status': 'failed', 'seconds': round(time.perf_counter() - started, 2)}


def local_translator(model, tokenizer, mx):
    """complete(messages, max_tokens, timeout) on the resident local model."""
    def complete(prompt, max_tokens, timeout):
        from mlx_lm import stream_generate
        from mlx_lm.sample_utils import make_sampler
        tokens = tokenizer.apply_chat_template(prompt, tokenize=True, add_generation_prompt=True, enable_thinking=False)
        started, output, last = time.perf_counter(), [], None
        events = stream_generate(model, tokenizer, prompt=tokens, max_tokens=max_tokens, sampler=make_sampler(temp=0))
        try:
            for event in events:
                output.append(event.text); last = event
                if time.perf_counter() - started > timeout:
                    raise TimeoutError('translation timed out')
        finally:
            events.close()
            mx.synchronize()
        if not last or last.finish_reason != 'stop':
            raise ValueError('translation exceeded its budget')
        return ''.join(output)
    return complete
