#!/usr/bin/env python3
"""Prepare or publish a signed Sparkle release from a clean, tested checkout."""
import argparse
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REPO = 'Zacklinkk/freetalk'
ACCOUNT = 'io.github.zacklinkk.freetalk'


def run(*args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def api(path, missing=False, payload=None):
    command = ['gh', 'api', path]
    if payload is not None:
        command += ['--method', 'POST', '--input', '-']
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None, text=True, capture_output=True)
    if result.returncode:
        if missing and 'HTTP 404' in result.stderr:
            return None
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def release_for_tag(tag):
    # GitHub's /releases/tags/{tag} endpoint does not reliably expose a draft
    # before its Git tag exists. The authenticated list includes our drafts.
    page = 1
    while True:
        releases = api(f'repos/{REPO}/releases?per_page=100&page={page}')
        for release in releases:
            if release['tag_name'] == tag:
                return release
        if len(releases) < 100:
            return None
        page += 1


def version_tuple(version):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version):
        raise ValueError('Use a stable major.minor.patch version')
    return tuple(map(int, version.split('.')))


def prepare(output, info, tag, previous=None):
    run('bash', str(ROOT/'scripts/build.sh'))
    app = ROOT/'build/freetalk.app'
    run('codesign', '--verify', '--deep', '--strict', str(app))
    output.mkdir(parents=True, exist_ok=True)
    archive = output/f'freetalk-{info["CFBundleShortVersionString"]}-macos-arm64.zip'
    notes = ROOT/'docs/releases'/f'{info["CFBundleShortVersionString"]}.md'
    if not notes.is_file():
        raise ValueError(f'Missing release notes: {notes.relative_to(ROOT)}')
    if previous:
        run('gh', 'release', 'download', previous['tag_name'], '--repo', REPO, '--pattern', 'appcast.xml', '--dir', str(output), '--clobber')
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
    # The native settings page displays plain text, without a remote web view.
    embedded_notes = archive.with_suffix('.txt')
    shutil.copyfile(notes, embedded_notes)
    sparkle = Path(run('bash', str(ROOT/'scripts/prepare-sparkle.sh'), capture_output=True).stdout.strip())
    command = [str(sparkle/'bin/generate_appcast'), '--download-url-prefix', f'https://github.com/{REPO}/releases/download/{tag}/',
               '--embed-release-notes', '--maximum-deltas', '0', '--maximum-versions', '3', '--link', f'https://github.com/{REPO}']
    # Never put private signing material in command-line arguments or logs.
    secret = os.environ.get('FREETALK_SPARKLE_PRIVATE_KEY')
    if secret:
        run(*command, '--ed-key-file', '-', str(output), input=secret+'\n')
    else:
        run(*command, '--account', ACCOUNT, str(output))
    feed = output/'appcast.xml'
    if not feed.is_file() or 'sparkle:edSignature=' not in feed.read_text():
        raise RuntimeError('Release feed is missing signed update assets')
    run('swift', str(ROOT/'scripts/verify-release.swift'), str(app/'Contents/Info.plist'), str(feed), str(archive))
    sums = output/'SHA256SUMS'
    sums.write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in [archive, feed]))
    return [archive, feed, sums], notes


def publish(output, info):
    version = info['CFBundleShortVersionString']; tag = 'v'+version
    run('git', '-C', str(ROOT), 'diff', '--exit-code')
    run('git', '-C', str(ROOT), 'diff', '--cached', '--exit-code')
    commit = run('git', '-C', str(ROOT), 'rev-parse', 'HEAD', capture_output=True).stdout.strip()
    existing = release_for_tag(tag)
    if existing and not existing['draft']:
        print(f'{tag} is already published; increase both version fields to publish another update.')
        return
    if existing and existing['target_commitish'] not in {commit}:
        raise RuntimeError('An unpublished draft for this version belongs to another commit; inspect it before retrying')
    previous = api(f'repos/{REPO}/releases/latest', missing=True)
    if previous and version_tuple(previous['tag_name'].removeprefix('v')) >= version_tuple(version):
        raise RuntimeError('Refusing to publish a version older than the latest release')
    if previous:
        # Release tags pin the old Info.plist; build numbers must rise as well.
        old = run('gh', 'api', f'repos/{REPO}/contents/native/Info.plist?ref={previous["tag_name"]}', '-H', 'Accept: application/vnd.github.raw+json', capture_output=True).stdout
        old_info = plistlib.loads(old.encode())
        if int(info['CFBundleVersion']) <= int(old_info['CFBundleVersion']):
            raise RuntimeError('CFBundleVersion must increase for Sparkle to offer this update')
    assets, notes = prepare(output, info, tag, previous)
    if not existing:
        existing = api(f'repos/{REPO}/releases', payload=dict(tag_name=tag,target_commitish=commit,draft=True,
                       name=f'freetalk {version}',body=notes.read_text()))
    run('gh', 'release', 'upload', tag, '--repo', REPO, '--clobber', *(str(p) for p in assets))
    uploaded = api(f'repos/{REPO}/releases/{existing["id"]}')
    remote = {row['name']: row for row in uploaded['assets']}
    for path in assets:
        row = remote.get(path.name)
        digest = 'sha256:'+hashlib.sha256(path.read_bytes()).hexdigest()
        if not row or row['size'] != path.stat().st_size or row.get('digest') != digest:
            raise RuntimeError('Uploaded asset did not match its local digest; release stays a draft')
    run('gh', 'release', 'edit', tag, '--repo', REPO, '--draft=false', '--latest')
    published = api(f'repos/{REPO}/releases/{existing["id"]}')
    if published['draft']:
        raise RuntimeError('Release is still a draft')
    print(published['html_url'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--publish', action='store_true', help='Upload only after all checks passed')
    args = parser.parse_args()
    info = plistlib.loads((ROOT/'native/Info.plist').read_bytes())
    version_tuple(info['CFBundleShortVersionString'])
    if not str(info['CFBundleVersion']).isdigit():
        raise ValueError('CFBundleVersion must be an increasing integer')
    output = ROOT/'build/releases'/('v'+info['CFBundleShortVersionString'])
    if args.publish:
        publish(output, info)
    else:
        assets, _ = prepare(output, info, 'v'+info['CFBundleShortVersionString'])
        print('\n'.join(str(path) for path in assets))
