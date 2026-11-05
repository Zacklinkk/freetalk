#!/usr/bin/env python3
"""Real signed updates against disposable apps; never reads personal freetalk data."""
import functools
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, text=True, check=True, **kwargs)


class TestServer(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def copyfile(self, source, output):
        try:
            while chunk := source.read(64*1024):
                output.write(chunk)
                if self.path.endswith('.zip'):
                    time.sleep(.02)  # Make cancellation observable, rather than racing a loopback download.
        except (BrokenPipeError, ConnectionResetError):
            pass


def main():
    if os.uname().sysname != 'Darwin':
        raise SystemExit('This integration check needs macOS with a GUI login session.')
    vendor = Path(run('bash', str(ROOT/'scripts/prepare-sparkle.sh'), capture_output=True).stdout.strip())
    output = ROOT/'build/tests/updater-integration'
    output.mkdir(parents=True, exist_ok=True)
    binary = output/'UpdateTest'
    run('swiftc', '-swift-version', '5', '-target', os.uname().machine+'-apple-macos14.0',
        str(ROOT/'native/AppUpdater.swift'), str(ROOT/'tests/UpdaterIntegrationHost.swift'),
        '-F', str(vendor), '-framework', 'Sparkle', '-framework', 'AppKit', '-framework', 'CryptoKit',
        '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', '-o', str(binary))
    outcomes = []
    with tempfile.TemporaryDirectory(prefix='freetalk-update-test-') as temp:
        working = Path(temp)
        key = working/'test.key'
        env = dict(os.environ, DYLD_FRAMEWORK_PATH=str(vendor))
        public = run(str(binary), '--make-test-key', str(key), capture_output=True, env=env).stdout.strip()
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(TestServer, directory=temp))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        origin = f'http://127.0.0.1:{server.server_port}'
        try:
            for case in ['install', 'latest', 'cancel', 'bad-feed', 'bad-archive', 'offline']:
                case_dir = working/case
                case_dir.mkdir()
                identifier = 'io.github.zacklinkk.freetalk.updater-test.'+uuid.uuid4().hex
                result = output/(case+'.json')
                result.unlink(missing_ok=True)
                result.with_suffix('.json.log').unlink(missing_ok=True)
                app = case_dir/'UpdateTest.app'
                contents = app/'Contents'
                (contents/'MacOS').mkdir(parents=True)
                (contents/'Frameworks').mkdir()
                shutil.copy2(binary, contents/'MacOS/UpdateTest')
                run('ditto', str(vendor/'Sparkle.framework'), str(contents/'Frameworks/Sparkle.framework'))
                info = dict(CFBundleIdentifier=identifier, CFBundleName='freetalk Update Test', CFBundleExecutable='UpdateTest',
                            CFBundlePackageType='APPL', CFBundleVersion='2', CFBundleShortVersionString='2.0.0',
                            LSMinimumSystemVersion='14.0', LSUIElement=True, SUEnableAutomaticChecks=False,
                            SUAutomaticallyUpdate=False, SUAllowsAutomaticUpdates=False, SUEnableSystemProfiling=False,
                            SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True, SUPublicEDKey=public,
                            SUFeedURL=f'{origin}/{case}/appcast.xml', FTTestScenario=case, FTTestResult=str(result),
                            NSAppTransportSecurity={'NSAllowsLocalNetworking': True})
                plist = contents/'Info.plist'
                plist.write_bytes(plistlib.dumps(info))
                run('codesign', '-f', '-s', '-', str(app), stderr=subprocess.DEVNULL)
                archive = case_dir/'UpdateTest.zip'
                run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(app), str(archive))
                run(str(vendor/'bin/generate_appcast'), '--ed-key-file', str(key), '--download-url-prefix', origin+'/'+case+'/',
                    '--maximum-deltas', '0', str(case_dir), stdout=subprocess.DEVNULL)
                if case != 'latest':
                    info.update(CFBundleVersion='1', CFBundleShortVersionString='1.0.0')
                if case == 'bad-feed':
                    feed = case_dir/'appcast.xml'
                    feed.write_bytes(feed.read_bytes().replace(b'2.0.0', b'9.0.0'))
                if case == 'bad-archive':
                    with archive.open('ab') as handle:
                        handle.write(b'tampered-after-signing')
                if case == 'offline':
                    (case_dir/'appcast.xml').unlink()
                plist.write_bytes(plistlib.dumps(info))
                run('codesign', '-f', '-s', '-', str(app), stderr=subprocess.DEVNULL)
                with (output/(case+'.process.log')).open('w') as log:
                    process = subprocess.Popen([str(contents/'MacOS/UpdateTest')], stdout=log, stderr=subprocess.STDOUT)
                    deadline = time.monotonic()+65
                    try:
                        while not result.exists() and time.monotonic() < deadline:
                            time.sleep(.1)
                        if not result.exists():
                            raise RuntimeError(f'{case} did not finish; inspect {output}')
                        observed = json.loads(result.read_text())
                        expected = {'install':'installed-and-relaunched','latest':'already-latest','cancel':'cancelled'}.get(case, 'rejected')
                        if observed['outcome'] != expected:
                            raise RuntimeError(f'{case}: {observed}')
                        disk_version = plistlib.loads(plist.read_bytes())['CFBundleVersion']
                        if disk_version != ('2' if case in {'install','latest'} else '1'):
                            raise RuntimeError(f'{case} changed the old app unexpectedly')
                        events = result.with_suffix('.json.log').read_text()
                        if case == 'bad-archive' and 'downloading:' not in events:
                            raise RuntimeError('Tampered archive was not actually downloaded')
                        if case == 'bad-feed' and 'available:' in events:
                            raise RuntimeError('An invalidly signed feed was accepted')
                        outcomes.append({'case':case,'outcome':expected,'disk_version':disk_version})
                        print(f'{case}: {expected}; app version {disk_version}', flush=True)
                    finally:
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.terminate(); process.wait(timeout=5)
        finally:
            server.shutdown()
    (output/'summary.json').write_text(json.dumps(outcomes, indent=2)+'\n')


if __name__ == '__main__':
    main()
