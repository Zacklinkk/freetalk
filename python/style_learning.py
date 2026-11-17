"""Cleanup habits learned from the user's own edits after insertion.

When the user deletes a filler that cleanup left (就是, 然后, 那个，), puts back a
word cleanup removed (吧, 这个), drops the final period in a chat, adds a comma
before a connective or a space between Chinese and English, the edit shows a
habit. Each habit becomes a lesson: a narrow, deterministic change applied
after cleanup, in the same position and, for tone, the same kind of app.

A lesson never rewrites content: it deletes a filler or particle, keeps a word,
or changes punctuation and spacing. A lesson that deletes or changes something
takes effect from its second observation, so one incidental edit changes
nothing; a lesson that keeps a word takes effect at once. Lessons fade after
about a month without being seen again, and an edit in the other direction
retires them. Larger rewrites teach nothing here; they still feed rule tuning.

Learning runs per watch session. Each call passes the whole session so far
(what was inserted and what the field shows now). The store remembers what
the session added or retired, so an edit the user reverts is unlearned and
undo takes back exactly this session's changes, even if the file was edited
in between (Settings can remove a lesson while a session is running).
"""
import difflib
import json
import re
import time
from pathlib import Path

HESITATIONS = ('嗯', '呃', '额', '啊', '哦')
FILLERS = ('就是说', '怎么说呢', '那个', '这个', '就是', '然后', '其实', '对吧', '对呀', '对啊', '对') + HESITATIONS
PARTICLES = ('吧', '呢', '啊', '呀', '哈', '嘛', '啦', '哦', '咯', '嘞', '呗')
# 还是 and 那么 are also adverbs (我还是觉得, 那么多); they are left out.
CONNECTIVES = ('然后', '但是', '所以', '因为', '而且', '不过', '或者', '如果', '另外', '同时', '并且', '而是', '否则', '因此')
# A demonstrative without a pause (那个文件) points at something; only 那个， is a filler.
NEEDS_PAUSE = ('那个', '这个', '对')
SUBJECT = r'(?:我们|你们|他们|她们|咱们|大家|我|你|您|他|她)'
SENTENCE_END, CLAUSE_END = '。！？!?\n', '，,、；;：:'
# Scopes are the kinds of app in native/AppCategories.swift, or the older scenes.
SCOPE_NAMES = {'all': '所有应用', 'chat': '聊天应用', 'work_chat': '工作沟通应用', 'email': '邮件', 'document': '文档',
               'notes': '笔记', 'code_editor': '代码编辑器', 'terminal': '终端', 'ai_chat': 'AI 对话', 'social': '社交应用',
               'meeting': '会议应用', 'task': '任务与项目', 'spreadsheet': '表格', 'presentation': '演示文稿', 'design': '设计工具',
               'browser': '其他网页', 'other': '其他应用',
               'conversation': '聊天应用', 'development': '开发工具', 'general': '一般应用'}
MAX_LESSONS = 100
HALF_LIFE_DAYS = 30


def key(lesson):
    return ':'.join(str(lesson.get(k, '')) for k in ('kind', 'word', 'where', 'mark', 'value', 'scope'))


def describe(lesson):
    kind, word = lesson['kind'], lesson.get('word', '')
    place = SCOPE_NAMES.get(lesson.get('scope'), lesson.get('scope'))
    if kind == 'drop':
        text = {'first': f'删除开头的“{word}”', 'start': f'删除句首的“{word}”', 'clause': f'删除逗号后的“{word}”',
                'mid': f'删除句中的“{word}”', 'end': f'删除句末的“{word}”'}[lesson['where']]
        return text if lesson['scope'] == 'all' else f'{place}里{text}'
    if kind == 'keep':
        return f'保留“{word}”' if lesson['scope'] == 'all' else f'{place}里保留“{word}”'
    if kind == 'final_mark':
        return f'{place}里句末不加句号' if not lesson['mark'] else f'{place}里句末加句号'
    if kind == 'comma_before':
        return f'在“{word}”前加逗号'
    if kind == 'question':
        return f'“{word}”结尾的句子用问号'
    if kind == 'spacing':
        return '中文和英文之间加空格' if lesson['value'] == 'space' else '中文和英文之间不加空格'
    return kind


def opposite(lesson):
    """Keys of the lessons this one contradicts."""
    kind, word, scope = lesson['kind'], lesson.get('word', ''), lesson['scope']
    if kind == 'keep':
        return {key({'kind': 'drop', 'word': word, 'where': w, 'scope': s}) for w in ('first', 'start', 'clause', 'mid', 'end') for s in ('all', scope)}
    if kind == 'drop':
        return {key({'kind': 'keep', 'word': word, 'scope': s}) for s in ('all', scope)}
    if kind == 'final_mark':
        return {key({'kind': 'final_mark', 'mark': '' if lesson['mark'] else '。', 'scope': scope})}
    if kind == 'spacing':
        return {key({'kind': 'spacing', 'value': 'none' if lesson['value'] == 'space' else 'space', 'scope': 'all'})}
    return set()


def threshold(lesson):
    """Observations a lesson needs before it changes text."""
    return 1 if lesson['kind'] == 'keep' else 2


def cjk(char):
    return bool(char) and '一' <= char <= '鿿'


def core(text):
    return re.sub(r'[\W_]', '', text)


def position(text, start, end):
    """Where text[start:end] sits: start of a sentence, after a pause, inside, or before a clause end."""
    before = text[:start].rstrip(' \t')
    after = text[end:].lstrip(' \t')
    if not before or before[-1] in SENTENCE_END:
        return 'start'
    if before[-1] in CLAUSE_END:
        return 'clause'
    if not after or after[0] in SENTENCE_END + CLAUSE_END:
        return 'end'
    return 'mid'


def lessons_from_edit(raw, inserted, current, scope='general'):
    """Lessons shown by the session's edit (inserted → current), and keys they retire."""
    if not inserted or inserted == current:
        return [], set()
    ops = [op for op in difflib.SequenceMatcher(a=inserted, b=current, autojunk=False).get_opcodes() if op[0] != 'equal']
    changed = sum(max(i2 - i1, j2 - j1) for _, i1, i2, j1, j2 in ops)
    # A rewrite is content, not a habit.
    if changed > max(30, .3 * len(inserted)):
        return [], set()
    lessons, retire = [], set()
    for tag, i1, i2, j1, j2 in ops:
        old, new = inserted[i1:i2], current[j1:j2]
        lead = len(old) - len(old.lstrip(' \t，,、；;：:'))
        trail = len(old) - len(old.rstrip(' \t，,、；;：:。.'))
        word = old[lead:len(old) - trail] if old.strip() else ''
        if tag == 'delete' and word and (word in FILLERS or word in PARTICLES):
            where = 'clause' if any(c in '，,、；;' for c in old[:lead]) else position(inserted, i1 + lead, i2 - trail)
            paused = any(c in '，,' for c in old[len(old) - trail:]) or inserted[i2:i2 + 1] in ('，', ',')
            if where == 'end' and word not in PARTICLES:
                where = 'mid'
            if where == 'mid' and word not in HESITATIONS:
                continue
            if word in NEEDS_PAUSE and not paused:
                continue
            # 然后 opening a dictation continues earlier text; later it orders steps.
            if word == '然后' and where == 'start':
                if inserted[:i1 + lead].strip():
                    continue
                where = 'first'
            lessons.append({'kind': 'drop', 'word': word, 'where': where, 'scope': scope if word in PARTICLES else 'all'})
        elif tag == 'insert' and core(new) and (core(new) in FILLERS or core(new) in PARTICLES):
            word = core(new)
            # Putting back what cleanup removed; a word the user adds is content.
            if raw.count(word) > inserted.count(word):
                lessons.append({'kind': 'keep', 'word': word, 'scope': scope if word in PARTICLES else 'all'})
        elif not core(old) and not core(new):
            lessons += punctuation_lessons(inserted, current, i1, i2, j1, j2, scope, retire)
    unique = {}
    for lesson in lessons:
        unique.setdefault(key(lesson), lesson)
    return list(unique.values()), retire


def punctuation_lessons(inserted, current, i1, i2, j1, j2, scope, retire):
    old, new = inserted[i1:i2], current[j1:j2]
    at_end = not inserted[i2:].strip()
    before = inserted[:i1].rstrip(' \t')[-1:]
    if at_end and old.strip() in ('。', '.') and not new.strip():
        return [{'kind': 'final_mark', 'mark': '', 'scope': scope}]
    if at_end and not old.strip() and new.strip() in ('。', '.') and (cjk(before) or before.isalnum()):
        return [{'kind': 'final_mark', 'mark': '。', 'scope': scope}]
    following = inserted[i2:].lstrip(' \t')
    if new.strip() in ('，', ',') and not old.strip() and cjk(before):
        word = next((w for w in CONNECTIVES if following.startswith(w)), None)
        if word:
            return [{'kind': 'comma_before', 'word': word, 'scope': 'all'}]
    if old.strip() in ('，', ',') and not new.strip():
        word = next((w for w in CONNECTIVES if following.startswith(w)), None)
        if word:
            retire.add(key({'kind': 'comma_before', 'word': word, 'scope': 'all'}))
    if old.strip() in ('。', '.') and new.strip() in ('？', '?') and before in PARTICLES + ('么',):
        return [{'kind': 'question', 'word': before, 'scope': 'all'}]
    left, right = inserted[i1 - 1:i1], inserted[i2:i2 + 1]
    latin = lambda c: c.isascii() and c.isalpha()
    if (cjk(left) and latin(right)) or (latin(left) and cjk(right)):
        if not old and new == ' ':
            return [{'kind': 'spacing', 'value': 'space', 'scope': 'all'}]
        if old == ' ' and not new:
            return [{'kind': 'spacing', 'value': 'none', 'scope': 'all'}]
    return []


def weight(lesson, now=None):
    days = max(0, ((now or time.time()) - lesson.get('last', 0)) / 86400)
    return lesson.get('count', 1) * .5 ** (days / HALF_LIFE_DAYS)


def is_active(lesson, now=None):
    return lesson.get('count', 1) >= threshold(lesson) and weight(lesson, now) >= threshold(lesson) * .25


def status(lesson, now=None):
    if is_active(lesson, now):
        return '已生效'
    missing = threshold(lesson) - lesson.get('count', 1)
    return f'再出现 {missing} 次后生效' if missing > 0 else '长期未出现，已暂停'


class StyleStore:
    """<support>/style-lessons.json, private to the user."""

    def __init__(self, support):
        self.path = Path(support) / 'style-lessons.json'
        # The newest watch session: lessons it counted and lessons it retired.
        self.sessions = {}

    def load(self):
        try:
            rows = json.loads(self.path.read_text()).get('lessons', [])
        except (OSError, ValueError, AttributeError):
            return []
        return [r for r in rows if isinstance(r, dict) and isinstance(r.get('kind'), str) and isinstance(r.get('scope'), str)]

    def save(self, rows):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        rows = sorted(rows, key=lambda r: -r.get('last', 0))[:MAX_LESSONS]
        temporary = self.path.with_suffix('.tmp')
        temporary.write_text(json.dumps({'lessons': rows}, ensure_ascii=False, indent=1))
        temporary.chmod(0o600)
        temporary.replace(self.path)

    def active(self, scope=None, now=None):
        return [r for r in self.load() if is_active(r, now) and (scope is None or r['scope'] in ('all', scope))]

    def learn(self, session, raw, inserted, current, scope='general', now=None):
        """Update the store for one session's edit so far. Returns the lessons newly counted by this call."""
        if session not in self.sessions:
            # Only the newest session can still change; older ones are final.
            self.sessions = {session: {'counted': set(), 'retired': {}}}
        state = self.sessions[session]
        if state is None:
            # The user took this session's lessons back; its later edits teach nothing.
            return []
        lessons, retire = lessons_from_edit(raw, inserted, current, scope)
        for lesson in lessons:
            retire |= opposite(lesson)
        wanted = {key(l): l for l in lessons}
        now = now or time.time()
        rows = {key(r): r for r in self.load()}
        before = json.dumps(rows, sort_keys=True)
        # An edit the user took back no longer counts, and its retirements return.
        for k in sorted(state['counted'] - set(wanted)):
            self._uncount(rows, k)
            state['counted'].discard(k)
        for k in sorted(set(state['retired']) - retire):
            rows.setdefault(k, state['retired'].pop(k))
        for k in sorted(retire):
            if k in rows and k not in state['retired']:
                state['retired'][k] = rows.pop(k)
        result = []
        for k, lesson in wanted.items():
            if k in state['counted']:
                continue
            row = rows.get(k)
            if row:
                row['count'] = row.get('count', 1) + 1
                row['last'] = now
            else:
                row = rows[k] = {**lesson, 'count': 1, 'last': now}
            state['counted'].add(k)
            result.append({'id': k, 'text': describe(row), 'count': row['count'], 'active': is_active(row, now)})
        if json.dumps(rows, sort_keys=True) != before:
            self.save(list(rows.values()))
        return result

    @staticmethod
    def _uncount(rows, k):
        row = rows.get(k)
        if row:
            row['count'] = row.get('count', 1) - 1
            if row['count'] <= 0:
                del rows[k]

    def undo(self, session):
        """Take back everything this session learned or retired."""
        state = self.sessions.get(session)
        if not state:
            return False
        self.sessions[session] = None
        rows = {key(r): r for r in self.load()}
        for k in state['counted']:
            self._uncount(rows, k)
        for k, row in state['retired'].items():
            rows.setdefault(k, row)
        self.save(list(rows.values()))
        return True

    def remove(self, lesson_id):
        self.save([r for r in self.load() if key(r) != lesson_id])

    def listing(self, now=None):
        return [{'id': key(r), 'text': describe(r), 'count': r.get('count', 1), 'active': is_active(r, now), 'status': status(r, now)}
                for r in self.load()]


def apply(text, context):
    """Apply the lessons in context['style'] to cleaned text. Returns (text, count)."""
    from edits import protected_span
    lessons = context.get('style') or []
    if not lessons or not text:
        return text, 0
    count = 0

    def sub(pattern, replacement, current):
        nonlocal count
        def replace(match):
            nonlocal count
            if protected_span(current, match.start(), match.end()):
                return match[0]
            value = replacement(match) if callable(replacement) else replacement
            if value != match[0]:
                count += 1
            return value
        return re.sub(pattern, replace, current)

    for lesson in lessons:
        kind, word = lesson['kind'], lesson.get('word', '')
        escaped = re.escape(word)
        if kind == 'drop':
            rest = r'(?=[^\s。！？!?，,])'
            if word in NEEDS_PAUSE:
                # 那个， is a pause; 那个文件 points at something.
                tail = r'[，,][ \t]*' + rest
            elif word == '就是':
                # Before a pause or a subject only: 就是这个。 is an answer.
                tail = r'(?:[，,][ \t]*' + rest + r'|(?=' + SUBJECT + r'))'
            else:
                tail = r'(?:[，,][ \t]*)?' + rest
            where = lesson['where']
            if where == 'first':
                text = sub(r'^[ \t]*' + escaped + tail, '', text)
            elif where == 'start':
                text = sub(r'(?:^|(?<=[。！？!?\n]))[ \t]*' + escaped + tail, '', text)
            elif where == 'clause':
                text = sub(r'(?<=[，,、；;：:])[ \t]*' + escaped + tail, '', text)
            elif where == 'mid':
                text = sub(r'(?<=[一-鿿])' + escaped + r'[，,]?(?=[一-鿿])', '', text)
            elif where == 'end':
                # Not in a question: 你来吗吧？ and 是吧？ ask something.
                text = sub(r'(?<=[一-鿿]{2})' + escaped + r'(?=[，,。！!]|$)', '', text)
        elif kind == 'final_mark':
            # A numbered list ends without a mark on purpose.
            if re.match(r'\d+\. ', text.rsplit('\n', 1)[-1]):
                continue
            if lesson['mark']:
                text = sub(r'(?<=[一-鿿A-Za-z0-9])$', '。', text)
            else:
                text = sub(r'(?<![.\d。])[。.]$', '', text)
        elif kind == 'comma_before':
            def comma(match, current=text):
                # Only after a clause of its own: 先测一遍如果不行 → ，如果; not 我如果.
                clause = re.split(r'[，,。！？!?；;：:\n]', current[:match.start()])[-1]
                return '，' if len(core(clause)) >= 6 else ''
            text = sub(r'(?<=[一-鿿])(?<![之正不也是就只])(?=' + escaped + r')', comma, text)
        elif kind == 'question':
            text = sub(r'(?<=' + escaped + r')。', '？', text)
        elif kind == 'spacing':
            if lesson['value'] == 'space':
                text = sub(r'(?<=[一-鿿])(?=[A-Za-z])|(?<=[A-Za-z])(?=[一-鿿])', ' ', text)
            else:
                text = sub(r'(?<=[一-鿿]) +(?=[A-Za-z])|(?<=[A-Za-z]) +(?=[一-鿿])', '', text)
    return text, count


def kept_words(lessons):
    """Words the user wants kept: cleanup must not delete them."""
    return sorted({l['word'] for l in lessons if l['kind'] == 'keep'})
