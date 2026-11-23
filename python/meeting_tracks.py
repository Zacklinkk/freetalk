"""Two-track meetings: the microphone (people in the room) and the sound the
Mac played (the remote side of a call), recorded side by side.

Each track is transcribed on its own, so the two sides never mix in one ASR
window; a speaker's track says who is local and who is remote. Where the
speakers' sound leaked into the microphone (no headphones), the microphone
repeats what the system track says at the same moment; those clauses are
dropped. Silence is skipped per track. Everything here is pure
Python except speech_levels, which reads audio.
"""
import math
import re
from bisect import bisect_left

LOCAL, REMOTE = '本机', '远端'
FRAME = 0.03


def core(text):
    return re.sub(r'[\W_]', '', text).lower()


def label_turns(turns, label):
    """A track's diarized turns renamed for the merged transcript: 远端1, 远端2 in
    order of first appearance; a track with one speaker keeps the bare name."""
    order = []
    for turn in sorted(turns, key=lambda t: t['start']):
        if turn['speaker'] not in order:
            order.append(turn['speaker'])
    names = {speaker: label if len(order) == 1 else f'{label}{i + 1}' for i, speaker in enumerate(order)}
    return [{**turn, 'speaker': names[turn['speaker']]} for turn in turns]


def regions(levels, label, frame=FRAME, floor=.0015, ceiling=.006, gap=.8, pad=.25, minimum=.3):
    """Where a track has sound, from frame levels (RMS per `frame` seconds).

    The threshold follows the track's own noise floor (a quiet room, digital
    silence on the system track), between `floor` (the level below which a
    meeting window has never been transcribed) and `ceiling` (so a soft voice
    in a noisy room still counts). Pauses shorter than `gap` stay inside one
    region, so a sentence is not cut at a breath.
    """
    if not levels:
        return []
    quiet = sorted(levels)[len(levels) // 10]
    threshold = min(ceiling, max(floor, 2.5 * quiet))
    spans, start, last = [], None, None
    for i, level in enumerate(levels):
        if level >= threshold:
            if start is None:
                start = i
            elif (i - last) * frame > gap:
                spans.append((start, last)); start = i
            last = i
    if start is not None:
        spans.append((start, last))
    total = len(levels) * frame
    return [{'start': max(0., a * frame - pad), 'end': min(total, (b + 1) * frame + pad), 'speaker': label}
            for a, b in spans if (b + 1 - a) * frame >= minimum]


def speech_windows(turns, gap=1.5, maximum=20.0, other=(), slack=.25):
    """ASR windows over a track's turns: only where someone speaks, cut where the speaker changes.

    A turn joins the window before it when it overlaps it, or when the same
    speaker goes on within `gap` seconds and the other track (`other`, turns
    in this track's time) neither starts nor stops speaking in between, so the
    two sides keep their order in the merged transcript. A window stays within
    `maximum` seconds; a longer turn is split evenly. Yields (start, end, speakers).
    """
    edges = sorted(p for t in other for p in (t['start'], t['end']))

    def crossed(b, start):
        # An echo's turn ends with the turn it echoes, a frame either way.
        i = bisect_left(edges, b - slack)
        return i < len(edges) and edges[i] <= start + slack
    windows = []
    for turn in sorted(turns, key=lambda t: (t['start'], t['end'])):
        start, end = turn['start'], turn['end']
        if windows:
            a, b, speakers = windows[-1]
            joins = start < b or (speakers == {turn['speaker']} and start - b < gap and not crossed(b, start))
            if joins and end - a <= maximum:
                windows[-1][1] = max(b, end); speakers.add(turn['speaker'])
                continue
            # Never transcribe the same moment twice.
            start = max(start, b)
            if end <= start:
                continue
        windows.append([start, end, {turn['speaker']}])
    for a, b, speakers in windows:
        n = max(1, math.ceil((b - a) / maximum))
        for i in range(n):
            yield a + (b - a) * i / n, a + (b - a) * (i + 1) / n, sorted(speakers)


def window_turns(windows, turns):
    """Overlap join for monotonically ordered windows. Never scan the full meeting per row."""
    ordered = iter(sorted(turns, key=lambda t: t['start']))
    following, active = next(ordered, None), []
    for window in windows:
        a, b = window[:2]
        active = [t for t in active if t['end'] > a]
        while following is not None and following['start'] < b:
            if following['end'] > a:
                active.append(following)
            following = next(ordered, None)
        yield window, [t for t in active if t['start'] < b]


def track_turns(levels, label, diarized=None):
    """A track's turns: the speaker model's (named 远端1, 远端2…), plus sound it
    left unassigned, so no speech is skipped; without the model, sound regions."""
    sound = regions(levels, label)
    if diarized is None:
        return sound
    found = label_turns(diarized, label)
    missed = [r for (_, _, r), nearby in window_turns(((r['start'], r['end'], r) for r in sound), found) if not nearby]
    return sorted(found + missed, key=lambda t: (t['start'], t['end']))


def own_turns(turns, other, cover=.7):
    """The turns not mostly covered by the other track's: on the microphone,
    the speakers' echo starts and stops with the remote speech it repeats."""
    windows = ((t['start'], t['end'], t) for t in sorted(turns, key=lambda t: t['start']))
    result = []
    for (a, b, turn), nearby in window_turns(windows, other):
        shared, end = 0., a
        for t in nearby:
            right = min(b, t['end'])
            shared += max(0., right - max(end, a, t['start']))
            end = max(end, right)
        if b <= a or shared < cover * (b-a):
            result.append(turn)
    return result


def speech_levels(path, frame=FRAME):
    """RMS per frame of a 16 kHz mono file, read in blocks (an 8-hour track stays small)."""
    import numpy as np
    import soundfile as sf
    size, levels = round(16000 * frame), []
    with sf.SoundFile(str(path)) as audio:
        while True:
            block = audio.read(size * 1000, dtype='float32')
            if len(block) == 0:
                return levels
            n = len(block) // size
            if n:
                levels += np.sqrt(np.mean(block[:n * size].reshape(n, size) ** 2, axis=1)).tolist()


def bigrams(text):
    return {text[i:i + 2] for i in range(len(text) - 1)}


def readings(text):
    """Each character's syllables without tones, every reading of a polyphone
    (露: lu, lou). The recognizer often hears an echo as homophones
    (别漏了 → 别露了), which share no characters but the same sounds."""
    try:
        from pypinyin import Style, pinyin
    except ImportError:
        return []
    return [set(r) for r in pinyin(text, style=Style.NORMAL, heteronym=True)]


def sound_pairs(syllables):
    return {(a, b) for x, y in zip(syllables, syllables[1:]) for a in x for b in y}


def strip_bleed(mic, system, margin=1.0, share=.6):
    """The microphone segment without the clauses that repeat what the speakers
    played at the same time. Returns (text, clauses dropped).

    A clause is an echo when most of its character pairs, or of its syllable
    pairs, occur in the system track's text from the same moment; the
    recognizer hears an echo slightly differently, and unrelated speech shares
    only common pairs (我们, 这个).
    A clause too short for that (另外，) is an echo when the system track has
    it and the clause next to it is one.
    """
    text = core(''.join(s['text'] for s in system if s['start'] < mic['end'] + margin and s['end'] > mic['start'] - margin))
    heard, heard_sounds = bigrams(text), sound_pairs(readings(text))
    if not heard:
        return mic['text'], 0
    clauses = [c for c in re.split(r'(?<=[。！？!?；;，,])', mic['text']) if c]
    echo = []
    for clause in clauses:
        said, syllables = bigrams(core(clause)), readings(core(clause))
        steps = list(zip(syllables, syllables[1:]))
        sounded = sum(any((a, b) in heard_sounds for a in x for b in y) for x, y in steps)
        echo.append(len(said) >= 2 and (len(said & heard) >= share * len(said) or (len(steps) >= 2 and sounded >= share * len(steps))))
    for i, clause in enumerate(clauses):
        short = core(clause)
        if not echo[i] and short and len(bigrams(short)) < 2 and short in text and any(echo[j] for j in (i - 1, i + 1) if 0 <= j < len(clauses)):
            echo[i] = True
    kept = ''.join(c for c, e in zip(clauses, echo) if not e)
    return kept.strip(' ，,'), sum(echo)


def renumber(rows, label):
    """The track's speakers named again after echo removal, by first appearance:
    an echo the speaker model counted as a person in the room is gone, and one
    person left is plain 本机."""
    order = []
    for row in rows:
        for speaker in row.get('speaker_ids', []):
            if speaker.startswith(label) and speaker not in order:
                order.append(speaker)
    names = {s: label if len(order) == 1 else f'{label}{i + 1}' for i, s in enumerate(order)}
    rename = lambda s: names.get(s, s)
    return [{**row, 'speaker_ids': [rename(s) for s in row.get('speaker_ids', [])],
             **({'speaker_turns': [{**t, 'speaker': rename(t['speaker'])} for t in row['speaker_turns']]} if 'speaker_turns' in row else {})}
            for row in rows]


def merge(mic, system):
    """Both tracks in time order with fresh IDs, echoes removed from the microphone.

    Returns (segments, clauses dropped as echo).
    """
    kept, dropped = [], 0
    windows = ((r['start']-1., r['end']+1., r) for r in sorted(mic, key=lambda r:r['start']))
    for (_, _, row), nearby in window_turns(windows, system):
        text, count = strip_bleed(row, nearby)
        dropped += count
        if core(text):
            kept.append({**row, 'text': text})
    kept = renumber(kept, LOCAL)
    rows = sorted([(row['start'], 0, row) for row in kept] + [(row['start'], 1, row) for row in system], key=lambda x: (x[0], x[1]))
    return [{**row, 'id': f's{i + 1:06}'} for i, (_, _, row) in enumerate(rows)], dropped
