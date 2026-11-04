"""Download pinned public model files; never read audio, history, or credentials.

Uses only the standard library. Partial downloads survive cancellation. Every
file is checked against the bundled SHA-256 manifest before configuration changes.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class SetupError(Exception):
    pass


def emit(**event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def valid_file(path, row):
    return path.is_file() and path.stat().st_size == row['size'] and sha256(path) == row['sha256']


def load_catalog(path):
    catalog = json.loads(path.read_text())
    if catalog.get('schema') != 1 or not catalog.get('models'):
        raise SetupError('模型清单版本不受支持')
    seen = set()
    for model in catalog['models']:
        if model['key'] not in {'asrModel', 'cleanupModel'} or not re.fullmatch(r'[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+', model['repo']):
            raise SetupError('模型来源无效')
        if not re.fullmatch(r'[0-9a-f]{40}', model['revision']):
            raise SetupError('模型版本未固定')
        if model['key'] in seen or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_.-]*', model['name']):
            raise SetupError('模型名称无效或重复')
        seen.add(model['key'])
        names = set()
        for row in model['files']:
            if not re.fullmatch(r'[a-zA-Z0-9_.-]+', row['name']) or row['name'].startswith('.') or row['name'] in names:
                raise SetupError('模型文件名无效')
            names.add(row['name'])
            if type(row['size']) is not int or row['size'] <= 0 or not re.fullmatch(r'[0-9a-f]{64}', row['sha256']):
                raise SetupError('模型校验信息无效')
        if not names or type(model['bytes']) is not int or model['bytes'] != sum(row['size'] for row in model['files']):
            raise SetupError('模型总大小与文件清单不一致')
    return catalog['models']


def fetch(url, target, row, progress=lambda amount: None, attempts=3):
    """Resume a partial file only when the server confirms the exact byte range."""
    target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    partial = target.with_name(target.name + '.partial')
    if valid_file(target, row):
        progress(row['size'])
        return
    for attempt in range(attempts):
        offset = partial.stat().st_size if partial.exists() else 0
        if offset >= row['size']:
            if valid_file(partial, row):
                os.replace(partial, target)
                progress(row['size'])
                return
            partial.unlink()
            offset = 0
        request = urllib.request.Request(url, headers={'User-Agent': 'freetalk-ModelSetup/0.2', 'Accept-Encoding': 'identity'})
        if offset:
            request.add_header('Range', f'bytes={offset}-')
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                status = response.status
                if status == 206:
                    match = re.fullmatch(r'bytes (\d+)-(\d+)/(\d+)', response.headers.get('Content-Range', ''))
                    if not match or int(match[1]) != offset or int(match[3]) != row['size']:
                        raise SetupError('服务器返回了不匹配的下载范围，请重试')
                elif status == 200:
                    offset = 0  # Range ignored: start fresh, never append a second file.
                else:
                    raise SetupError(f'下载失败（HTTP {status}）')
                mode = 'ab' if offset else 'wb'
                with partial.open(mode) as dest:
                    os.chmod(partial, 0o600)
                    received = offset
                    last = 0.0
                    while True:
                        block = response.read(1024 * 1024)
                        if not block:
                            break
                        received += len(block)
                        if received > row['size']:
                            raise SetupError('下载大小不符合模型清单')
                        dest.write(block)
                        now = time.monotonic()
                        if now - last > .2:
                            progress(received)
                            last = now
            if not valid_file(partial, row):
                if partial.stat().st_size == row['size']:
                    partial.unlink()  # Complete but corrupt bytes cannot be resumed.
                raise SetupError('文件校验未通过，可点击重试继续下载')
            os.replace(partial, target)
            progress(row['size'])
            return
        except (OSError, urllib.error.URLError, SetupError) as error:
            if attempt + 1 == attempts:
                raise SetupError(f'{target.name}：{error}') from error
            time.sleep(min(2 ** attempt, 4))


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.tmp')
    try:
        with temporary.open('w') as dest:
            os.chmod(temporary, 0o600)
            json.dump(value, dest, ensure_ascii=False, indent=2)
            dest.write('\n')
            dest.flush()
            os.fsync(dest.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def install(support, python, catalog, only='all', notify=emit):
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    config_path = support / 'config.json'
    try:
        config = json.loads(config_path.read_text()) if config_path.exists() else {}
        if not isinstance(config, dict):
            raise ValueError('not an object')
    except (ValueError, OSError) as error:
        raise SetupError('现有配置无法读取；已保留原文件，请先修复配置') from error
    models = [m for m in load_catalog(catalog) if only in {'all', m['key']}]
    if not models:
        raise SetupError('未选择可下载模型')
    total = sum(m['bytes'] for m in models)
    completed = 0
    for model in models:
        notify(event='progress', stage='verify', message=f"检查 {model['title']}文件…", completed=completed, total=total)
        existing = Path(config[model['key']]) if isinstance(config.get(model['key']), str) else None
        if existing and all(valid_file(existing / row['name'], row) for row in model['files']):
            completed += model['bytes']
            notify(event='progress', stage='verified', message=f"{model['title']}已校验，无需下载", completed=completed, total=total)
            continue
        directory = support / 'runtime' / 'models' / model['name'] / model['revision']
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        # Invalid existing files are kept until their replacement is verified,
        # so they still require room for a full replacement download.
        needed = 0
        for row in model['files']:
            target = directory / row['name']
            if valid_file(target, row):
                continue
            partial = target.with_name(target.name + '.partial')
            offset = partial.stat().st_size if partial.is_file() else 0
            if offset >= row['size'] and not valid_file(partial, row):
                offset = 0
            needed += max(0, row['size'] - offset)
        if shutil.disk_usage(support).free < needed + 256 * 1024 * 1024:
            raise SetupError('磁盘空间不足，请释放空间后重试；已有模型未改动')
        for row in model['files']:
            url = f"https://huggingface.co/{model['repo']}/resolve/{model['revision']}/{urllib.parse.quote(row['name'])}"
            def update(amount):
                notify(event='progress', stage='download', message=f"{model['title']} · {row['name']}", completed=completed + amount, total=total)
            fetch(url, directory / row['name'], row, update)
            completed += row['size']
        atomic_json(directory / 'freetalk-manifest.json', model)
        config[model['key']] = str(directory)
    defaults = {'maxRecordingSeconds': 90, 'cleanupTimeoutSeconds': 6, 'segmentMinSeconds': 8,
                'segmentMaxSeconds': 20, 'silenceRms': .008, 'residentGiB': 5}
    for key, value in defaults.items():
        config.setdefault(key, value)
    config['python'] = str(python)
    atomic_json(config_path, config)
    notify(event='complete', message='下载和校验完成', completed=total, total=total)
    return config


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--support', type=Path, required=True)
    parser.add_argument('--python', type=Path, required=True)
    parser.add_argument('--catalog', type=Path, default=Path(__file__).with_name('catalog.json'))
    parser.add_argument('--only', choices=['all', 'asrModel', 'cleanupModel'], default='all')
    args = parser.parse_args()
    os.umask(0o077)
    try:
        install(args.support, args.python, args.catalog, args.only)
    except Exception as error:
        emit(event='error', message=str(error))
        raise SystemExit(1)
