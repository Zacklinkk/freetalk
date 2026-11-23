"""In-app end-to-end checks with an E2E build of freetalk (scripts/build-e2e.sh).

usage: python3 -I scripts/e2e/run.py [--force] [--wait-idle SECONDS] [check ...]
checks: translate rich learn ocr meeting nightly (default: all, in this order)

The checks bring TextEdit to the front and press freetalk's shortcuts, so
nobody should use the Mac meanwhile. --wait-idle starts only after the
keyboard and mouse have been idle that long (and waits again before each
check); a check that loses the front window fails and its recording is
cancelled. Nothing is pressed while the screen is locked; checks left when it
locks are skipped. The run never keeps the Mac awake or unlocked.

Needs Accessibility, Input Monitoring, Microphone and Screen Recording for
freetalk, TextEdit, and the BlackHole 2ch virtual audio device: the test's
voice reaches freetalk through it, so dictation plays nothing in the room. The
meeting check plays the remote side to the default output (it may be muted).
The nightly check needs the strong model's key in FREETALK_E2E_CLOUD_KEY and,
if the service wants them, extra headers as JSON in FREETALK_E2E_CLOUD_HEADERS.
They reach the app in a 0600 file that is deleted once the app has started.

The installed freetalk is quit (only when its last dictation is 30 minutes
old, unless --force) and started again at the end. The E2E build runs on a
throwaway support directory with synthetic history and cases, so nothing of
the user's is read or sent. freetalk's preferences are exported first and
restored at the end. TextEdit documents are created in the work directory.
The build lives in build/freetalk-e2e.app; never install or publish it.
"""
import json, os, plistlib, shutil, subprocess, sys, time
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'build' / 'freetalk-e2e.app'
DOMAIN = 'io.github.zacklinkk.freetalk'
WORK = Path('/tmp/freetalk-e2e')
SUPPORT = WORK / 'support'
REAL_SUPPORT = Path.home() / 'Library/Application Support/freetalk'
MIC, MIC_UID = 'BlackHole 2ch', 'BlackHole2ch_UID'
LOCAL, REMOTE, REMOTE2 = 'Tingting', 'Eddy (中文（中国大陆）)', 'Flo (中文（中国大陆）)'
CHECKS = ['translate', 'rich', 'learn', 'ocr', 'meeting', 'nightly']
results = {}


def sh(*cmd, check=True, **kw):
    return subprocess.run([str(c) for c in cmd], check=check, capture_output=True, text=True, **kw)


def send(command, timeout=40, **values):
    out = sh(WORK / 'send', SUPPORT, command, *[f'{k}={v}' for k, v in values.items()],
             env={**os.environ, 'E2E_TIMEOUT': str(timeout)}, check=False)
    if out.returncode:
        raise RuntimeError(out.stderr.strip() or f'no reply to {command}')
    return json.loads(out.stdout)


def ask(command, **values):
    try:
        return send(command, timeout=5, **values)
    except (RuntimeError, ValueError):
        return None


def wait(what, test, timeout, every=0.5):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = test()
        if value:
            return value
        time.sleep(every)
    raise TimeoutError(f'timed out waiting for {what}')
def idle_seconds():
    out = sh('ioreg', '-c', 'IOHIDSystem', check=False).stdout
    for line in out.splitlines():
        if 'HIDIdleTime' in line:
            return int(line.split('=')[-1]) / 1e9
    return 0


def locked():
    """The screen is locked: keys would go to the password field, so nothing is pressed."""
    out = sh('ioreg', '-n', 'Root', '-d1', '-a', check=False).stdout
    try:
        return bool(plistlib.loads(out.encode()).get('IOConsoleLocked'))
    except Exception:
        return True


def wait_idle(seconds, limit=8 * 3600):
    if seconds:
        wait(f'{seconds} s without keyboard or mouse use, screen unlocked', lambda: idle_seconds() >= seconds and not locked(), limit, every=10)


def running():
    """(pid, app bundle) of every running freetalk, installed or built."""
    rows = []
    for pid in sh('pgrep', '-f', r'freetalk(-e2e)?\.app/Contents/MacOS/freetalk', check=False).stdout.split():
        path = sh('ps', '-o', 'comm=', '-p', pid, check=False).stdout.strip()
        if path.endswith('.app/Contents/MacOS/freetalk'):
            rows.append((int(pid), Path(path).parents[2]))
    return rows


def quit_freetalk():
    if not running():
        return
    sh('osascript', '-e', f'tell application id "{DOMAIN}" to quit', check=False)
    try:
        wait('freetalk to quit', lambda: not running(), 30)
    except TimeoutError:
        for pid, _ in running():
            os.kill(pid, 15)
        wait('freetalk to stop', lambda: not running(), 15)


def last_dictation():
    """When the user last dictated; only the dates of the real history are read."""
    try:
        rows = json.loads((REAL_SUPPORT / 'history.json').read_text())
        return max(datetime.fromisoformat(r['createdAt'].replace('Z', '+00:00')) for r in rows)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def unused(minutes=30):
    """freetalk has not been used for dictation in the last `minutes`."""
    last = last_dictation()
    return not last or datetime.now(timezone.utc) - last >= timedelta(minutes=minutes)


def restore_defaults(backup):
    sh('defaults', 'delete', DOMAIN, check=False)
    sh('defaults', 'import', DOMAIN, backup)
    after = WORK / 'defaults-restored.plist'
    sh('defaults', 'export', DOMAIN, after)
    return plistlib.loads(after.read_bytes()) == plistlib.loads(backup.read_bytes())


def audio_defaults():
    """The system's default input and output devices and their transports, for the record."""
    try:
        rows = json.loads(sh('system_profiler', '-json', 'SPAudioDataType', check=False).stdout)['SPAudioDataType'][0]['_items']
    except (ValueError, KeyError, IndexError, TypeError):
        return {}
    found = {}
    for row in rows:
        for key, name in (('coreaudio_default_audio_input_device', 'input'), ('coreaudio_default_audio_output_device', 'output')):
            if row.get(key) == 'spaudio_yes':
                found[name] = f"{row.get('_name', '')} ({row.get('coreaudio_device_transport', '').replace('coreaudio_device_type_', '')})"
    return found


def stamp(minutes_ago):
    return (datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)).strftime('%Y-%m-%dT%H:%M:%SZ')


# Invented dictations about one field, so the profile step has something to find.
TOPICS = ['今天的 benchmark 跑完了，SFT 之后的 checkpoint 分数提高了两个点。',
          '这个 LoRA 的学习率再调小一点，然后重新跑一遍评测。',
          '召回率还可以，但是推理延迟太高，需要再看一下 batch size。',
          '把新的数据集加到 benchmark 里，记得去掉重复的样本。',
          'checkpoint 保存的频率改成每一千步一次。',
          '评测的 rubric 要写清楚，每一条都要有打分标准。',
          'SFT 的数据先抽样检查一百条，看看标注质量。',
          'prompt 里的示例太长了，换成短一点的版本再测。',
          '推理延迟主要卡在 tokenizer 上，可以先做缓存。']


def synthetic_history(count=25):
    rows = []
    for i in range(count):
        text = TOPICS[i % len(TOPICS)]
        rows.append({'id': f'e2e-{i:03d}', 'createdAt': stamp(60 * (i + 2)), 'text': text, 'raw': text, 'targetApp': 'TextEdit',
                     'insertionStatus': '已插入', 'audioSeconds': 5.0, 'stopToTextSeconds': 1.0, 'cleanupSeconds': 0.5,
                     'cleanupStatus': '快速规则', 'modelUsed': False})
    return rows


def synthetic_cases():
    """Invented edits after insertion: the user deleted fillers cleanup left."""
    pairs = [('就是我们明天先把测试跑完，然后再发布。', '我们明天先把测试跑完，然后再发布。'),
             ('那个，你帮我看一下这个日志。', '你帮我看一下这个日志。'),
             ('就是这个接口的返回太慢了，我们得优化。', '这个接口的返回太慢了，我们得优化。'),
             ('那个，周五之前把文档发我一下。', '周五之前把文档发我一下。')]
    return [{'raw': a, 'inserted': a, 'final': b, 'createdAt': stamp(30 * (i + 1))} for i, (a, b) in enumerate(pairs)]


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=1))
    path.chmod(0o600)


def prepare():
    if WORK.exists():
        if not (WORK / '.freetalk-e2e').exists():
            sys.exit(f'{WORK} exists and was not made by this script; move it away first.')
        shutil.rmtree(WORK)
    SUPPORT.mkdir(parents=True, mode=0o700)
    (WORK / '.freetalk-e2e').write_text('Work directory of scripts/e2e/run.py; safe to delete.\n')
    # Model paths only; no history, words or lessons of the user's.
    shutil.copy(REAL_SUPPORT / 'config.json', SUPPORT / 'config.json')
    (SUPPORT / '.legacy-imported').write_text('E2E: the user\'s older files are not imported.\n')
    write_json(SUPPORT / 'meeting-settings.json', {'enabled': True, 'diarization': False, 'system_audio': True,
                                                     'retain_audio': True, 'summary_mode': 'local'})
    write_json(SUPPORT / 'history.json', synthetic_history())
    write_json(SUPPORT / 'cleanup-feedback.json', synthetic_cases())
    sh('swiftc', '-swift-version', '5', ROOT / 'scripts/e2e/send.swift', '-o', WORK / 'send')
EMPTY_RTF = '{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n\\f0\\fs32 }'


def launch():
    env = ['--env', f'FREETALK_E2E_SUPPORT={SUPPORT}']
    secret = WORK / 'cloud.json'
    if os.environ.get('FREETALK_E2E_CLOUD_KEY'):
        # Never on a command line, where other processes could read it.
        fd = os.open(secret, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as out:
            json.dump({'key': os.environ['FREETALK_E2E_CLOUD_KEY'], 'headers': json.loads(os.environ.get('FREETALK_E2E_CLOUD_HEADERS') or '{}')}, out)
        env += ['--env', f'FREETALK_E2E_CLOUD_FILE={secret}']
    try:
        sh('open', '-n', '-F', *env, APP)
        wait('the E2E build to answer', lambda: ask('status'), 60, every=1)
    finally:
        secret.unlink(missing_ok=True)
    wait('the local models to load', lambda: (ask('status') or {}).get('worker_ready'), 300, every=2)


def front(tries=3):
    """TextEdit in front with a text view focused; False when it would not stay there."""
    if locked():
        return False
    for _ in range(tries):
        sh('osascript', '-e', 'tell application "TextEdit" to activate', check=False)
        time.sleep(0.6)
        if (ask('read') or {}).get('role') == 'AXTextArea':
            return True
    return False


def document(name):
    """A new rich-text TextEdit document in front, with its text view focused."""
    path = WORK / f'{name}.rtf'
    path.write_text(EMPTY_RTF)
    sh('open', '-a', 'TextEdit', path)
    wait('TextEdit to show the document', front, 30)
    # A TextEdit that was just launched may still restore windows or show its
    # open panel; the document must still have the focus a moment later.
    time.sleep(2)
    wait('TextEdit to settle on the document', lambda: front(tries=1), 30)
    return path


def history():
    return send('history')['entries']


def dictate(text, key='dictation', voice=LOCAL):
    """Press the shortcut, speak through the virtual microphone, press it again.

    Returns the new history entry once the paste has been checked.
    """
    seen = {e['id'] for e in history()}
    if not front() or not send('key', binding=key).get('posted'):
        raise RuntimeError('TextEdit did not stay in front; the shortcut was not pressed')
    wait('recording to start', lambda: (ask('status') or {}).get('phase') == 'recording', 20)
    time.sleep(0.5)
    sh('say', '-v', voice, '-a', MIC, text)
    time.sleep(1.0)
    if not front() or not send('key', binding=key).get('posted'):
        ask('cancel')
        raise RuntimeError('TextEdit lost the front before the recording was stopped; it was cancelled')

    def inserted():
        return next((e for e in history() if e['id'] not in seen and e['insertion'] != '等待输入'), None)
    entry = wait('the dictation to be inserted', inserted, 120, every=1)
    wait('freetalk to be idle', lambda: (ask('status') or {}).get('phase') == 'idle', 30)
    return entry


def pasted(entry):
    return entry['insertion'].startswith('已插入')


def check_translate():
    if not (ask('status') or {}).get('translation_key'):
        return {'ok': False, 'blocked': 'the translation shortcut is off'}
    document('translate')
    entry = dictate('请在周五之前把测试报告发给我。', key='translation')
    value = send('read').get('value', '')
    english = sum(c.isascii() and c.isalpha() for c in value) >= 10 and not any('一' <= c <= '鿿' for c in value)
    return {'ok': pasted(entry) and english, 'field': value, 'insertion': entry['insertion'], 'cleanup': entry['cleanup']}


def check_rich():
    path = document('rich')
    entry = dictate('接下来要做三件事。第一，补齐单元测试。第二，更新使用文档。第三，发布新版本。')
    sh('osascript', '-e', 'tell application "TextEdit" to save (first document whose path contains "freetalk-e2e/rich")', check=False)
    rtf = path.read_text(errors='replace')
    listed = '\\listtable' in rtf and '{\\listtext' in rtf
    return {'ok': pasted(entry) and listed, 'text': entry['text'], 'rtf_has_list': listed, 'insertion': entry['insertion']}
def notes(entry_id):
    return next((e['learned'] for e in history() if e['id'] == entry_id), [])


def check_learn():
    """Delete the final full stop twice: the habit applies from the second time on."""
    document('learn')
    sessions = []
    for text in ['好的，我明天把评测报告发给你。', '收到，我下午就开始改。']:
        send('edit', value='')
        entry = dictate(text)
        value = send('read').get('value', '').rstrip()
        if not value.endswith('。'):
            return {'ok': False, 'error': 'the dictation did not end with a full stop', 'field': value}
        send('edit', value=value[:-1])
        sessions.append(wait('the habit to be noted', lambda: [n for n in notes(entry['id']) if '整理习惯' in n], 30))
    send('edit', value='')
    third = dictate('那我们周四再对一下进度。')
    applied = pasted(third) and not third['text'].rstrip().endswith('。')
    learned = any('已学会整理习惯' in n for n in sessions[1]) and any('再出现一次后生效' in n for n in sessions[0])
    return {'ok': learned and applied, 'first': sessions[0], 'second': sessions[1], 'third_text': third['text']}


def blocked():
    """Why a check that needs Screen Recording cannot run; only the user can grant it."""
    if not (ask('status') or {}).get('screen'):
        return {'ok': False, 'blocked': 'freetalk 没有“屏幕录制”权限：系统设置 → 隐私与安全性 → 屏幕与系统录音，打开 freetalk'}


def check_ocr():
    if blocked():
        return blocked()
    document('ocr')
    send('edit', value='freetalk 端到端测试 7319\n夏普比率与 Kubernetes 灰度发布')
    time.sleep(1.5)
    reply = send('ocr', timeout=90, expect='7319|夏普比率|Kubernetes')
    return {'ok': bool(reply.get('permitted')) and not reply.get('missing'), **{k: reply.get(k) for k in ('permitted', 'characters', 'found', 'missing', 'seconds', 'error')}}


# The remote side plays to the default output (the system track). "echo" lines
# also reach the virtual microphone, as speakers without headphones would.
SCRIPT = [('remote', REMOTE, '大家好，今天主要对一下评测报告的进度。'),
          ('local', LOCAL, '好的，我这边评测脚本已经跑完了，结果在共享文档里。'),
          ('echo', REMOTE2, '我看了一下，召回率比上个版本高了三个点。'),
          ('local', LOCAL, '延迟主要是长音频的切分导致的，我周四之前改完。'),
          ('echo', REMOTE, '那发布就定在下周二，周一下午再过一遍回归测试。'),
          ('local', LOCAL, '没问题，回归测试的清单我今天发到群里。')]


def check_meeting():
    """A call: the remote side plays to the Mac's output, the local side and the
    speakers' echo reach the microphone. Without Screen Recording the meeting is
    recorded from the microphone only, which checks that path instead."""
    import re
    two = bool((ask('status') or {}).get('screen'))
    send('meeting-option', system_audio='true' if two else 'false')
    document('meeting')
    if not front() or not send('key', binding='meeting').get('posted'):
        raise RuntimeError('the meeting shortcut was not posted')
    wait('the meeting to record', lambda: (ask('meeting') or {}).get('status') == 'recording', 30)
    time.sleep(2)
    for side, voice, text in SCRIPT:
        if side == 'local':
            sh('say', '-v', voice, '-a', MIC, text)
        elif side == 'remote':
            sh('say', '-v', voice, text)
        else:
            leak = subprocess.Popen(['say', '-v', voice, '-a', MIC, text])
            sh('say', '-v', voice, text)
            leak.wait()
        time.sleep(0.8)
    time.sleep(1)
    if not front() or not send('key', binding='meeting').get('posted'):
        raise RuntimeError('the shortcut to end the meeting could not be pressed')
    final = wait('the meeting to be processed', lambda: (m := ask('meeting')) and m.get('status') in ('complete', 'failed') and m, 900, every=3)
    folder = Path(final.get('folder', ''))
    transcript = (folder / 'transcript.md').read_text() if (folder / 'transcript.md').exists() else ''
    labels = sorted(set(re.findall(r'· ((?:本机|远端)\d*)$', transcript, re.M)))
    once = {word: transcript.count(word) for word in ('召回率', '下周二')}
    if two:
        ok = (final.get('status') == 'complete' and final.get('tracks') == 2 and {'本机', '远端'} <= set(labels)
              and all(n == 1 for n in once.values()) and (final.get('echo_clauses_dropped') or 0) >= 1)
    else:
        ok = final.get('status') == 'complete' and not final.get('tracks') and (final.get('segment_count') or 0) >= 1 and '评测' in transcript
    result = {'ok': ok, 'tracks_checked': 2 if two else 1, 'labels': labels, 'echo_lines_in_transcript': once,
              **{k: final.get(k) for k in ('status', 'tracks', 'system_offset_seconds', 'echo_clauses_dropped', 'segment_count', 'processing_seconds', 'error', 'files')}}
    if not two:
        result['blocked'] = blocked()['blocked'] + '（本次只验证了单轨会议）'
    return result


def check_nightly():
    if not os.environ.get('FREETALK_E2E_CLOUD_KEY'):
        return {'ok': False, 'skipped': 'FREETALK_E2E_CLOUD_KEY is not set'}
    if not send('nightly-due', hour='1').get('started'):
        return {'ok': False, 'error': 'the nightly run did not start', 'status': ask('nightly-status')}
    final = wait('nightly maintenance to finish', lambda: (s := ask('nightly-status')) and not s.get('busy') and s, 1800, every=5)
    report = final.get('report', '')
    path = SUPPORT / 'user-profile.json'
    profile = json.loads(path.read_text()) if path.exists() else {}
    ok = bool(profile.get('terms')) and '画像：已更新' in report and '整理规则：' in report
    return {'ok': ok, 'report': report, 'domains': profile.get('domains'), 'terms': profile.get('terms'),
            'profile_mode': oct(path.stat().st_mode & 0o777) if path.exists() else None}


def main():
    args = sys.argv[1:]
    idle = int(args.pop(args.index('--wait-idle') + 1)) if '--wait-idle' in args else 0
    checks = [a for a in args if not a.startswith('--')] or CHECKS
    if set(checks) - set(CHECKS):
        sys.exit(f'unknown checks: {sorted(set(checks) - set(CHECKS))}')
    if not APP.exists():
        sys.exit('build the E2E app first: bash scripts/build-e2e.sh')
    if MIC not in sh('say', '-a', '?').stdout:
        sys.exit('the BlackHole 2ch audio device is missing')
    force = '--force' in sys.argv
    if idle:
        # Waiting anyway: also wait until freetalk has not been used for 30 minutes.
        wait(f'{idle} s without keyboard or mouse use, screen unlocked, no dictation for 30 minutes',
             lambda: idle_seconds() >= idle and not locked() and (force or unused()), 8 * 3600, every=10)
    elif not force and not unused():
        sys.exit('freetalk was used in the last 30 minutes; try again later, pass --wait-idle SECONDS or --force')
    prepare()
    was, textedit = running(), sh('pgrep', '-x', 'TextEdit', check=False).returncode == 0
    quit_freetalk()
    backup = WORK / 'defaults-backup.plist'
    sh('defaults', 'export', DOMAIN, backup)
    try:
        for key, kind, value in [('micFollowSystem', '-bool', 'false'), ('micUID', '-string', MIC_UID),
                                 ('learnCorrections', '-bool', 'true'), ('richTextPaste', '-bool', 'true'),
                                 ('translationShortcutEnabled', '-bool', 'true'), ('nightlyMaintenance', '-bool', 'true'),
                                 ('nightlyProfile', '-bool', 'true'), ('cloudNightlyTuning', '-bool', 'true')]:
            sh('defaults', 'write', DOMAIN, key, kind, value)
        launch()
        results['audio_defaults'] = audio_defaults()
        results['status'] = send('status')
        print('status', json.dumps(results['status'], ensure_ascii=False), flush=True)
        for name in checks:
            if locked():
                results[name] = {'ok': False, 'skipped': 'the screen locked during the run'}
                continue
            try:
                wait_idle(min(idle, 20), limit=3600)
                results[name] = globals()['check_' + name]()
            except Exception as error:
                results[name] = {'ok': False, 'error': f'{type(error).__name__}: {error}', 'status': ask('status')}
                ask('cancel')
            print(name, json.dumps(results[name], ensure_ascii=False), flush=True)
    finally:
        quit_freetalk()
        if sh('pgrep', '-x', 'TextEdit', check=False).returncode == 0:
            # Only the test's documents; anything else the user has open stays.
            sh('osascript', '-e', 'tell application "TextEdit" to close (every document whose path contains "freetalk-e2e") saving no', check=False)
            if not textedit:
                sh('osascript', '-e', 'tell application "TextEdit" to if (count of documents) is 0 then quit', check=False)
        results['defaults_restored'] = restore_defaults(backup)
        for _, bundle in was[:1]:
            sh('open', bundle, check=False)
        results['restarted'] = str(was[0][1]) if was else None
        write_json(WORK / 'results.json', results)
        # The test's data directory goes: anything dictated into the test build by
        # mistake while it ran stays out of reach. Its log is kept for diagnosis.
        if (SUPPORT / 'engine.log').exists():
            shutil.copy(SUPPORT / 'engine.log', WORK / 'engine.log')
        try:
            results['microphone_start'] = json.loads((SUPPORT / 'last-microphone-start.json').read_text())
            write_json(WORK / 'results.json', results)
        except (OSError, ValueError):
            pass
        shutil.rmtree(SUPPORT, ignore_errors=True)
    print(json.dumps({k: v.get('ok') if isinstance(v, dict) and 'ok' in v else v for k, v in results.items() if k != 'status'}, ensure_ascii=False))


if __name__ == '__main__':
    main()
