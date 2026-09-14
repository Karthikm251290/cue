#!/usr/bin/env python3
"""Install a locally built bundle, preserving a rollback copy and SQLite backup."""
import fcntl
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import time

source = Path(__file__).resolve().parent.parent / 'dist/Cue.app'
target = Path.home() / 'Applications/Cue.app'
root = Path.home() / 'Library/Application Support/SessionControl'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
root.mkdir(parents=True, exist_ok=True, mode=0o700)
target.parent.mkdir(parents=True, exist_ok=True)
# Match only this installed executable; never terminate provider sessions.
legacy = target.parent / 'Session Control.app'
executables = {str(app / 'Contents/MacOS/SessionControl') for app in (target, legacy)}
for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
    row = line.strip().split(maxsplit=1)
    if len(row) == 2 and row[1] in executables:
        os.kill(int(row[0]), signal.SIGTERM)
with (root / 'app.lock').open('a') as lock:
    for attempt in range(30):
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            time.sleep(0.1)
    else:
        raise SystemExit('App is still running. Quit it before upgrading.')
    stamp = time.strftime('%Y%m%d-%H%M%S')
    database = root / 'sessions.sqlite'
    if database.exists():
        backup = root / f'sessions-before-{stamp}.sqlite'
        with sqlite3.connect(f'file:{database}?mode=ro', uri=True) as db:
            with sqlite3.connect(backup) as copy:
                db.backup(copy)
        backup.chmod(0o600)
    with tempfile.TemporaryDirectory(prefix='.session-control-install-', dir=target.parent) as folder:
        staged = Path(folder) / target.name
        subprocess.run(['ditto', str(source), str(staged)], check=True)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        previous = target.parent / f'Cue before {stamp}.app'
        if target.exists():
            target.rename(previous)
        try:
            staged.rename(target)
        except Exception:
            if previous.exists():
                previous.rename(target)
            raise
    if legacy.exists():
        legacy.rename(target.parent / f'Session Control before Cue {stamp}.app')
    helper = root / 'bin/SessionReporter'
    if helper.exists():
        temporary = helper.with_suffix('.new')
        temporary.write_bytes((target / 'Contents/Helpers/SessionReporter').read_bytes())
        temporary.chmod(0o700)
        temporary.replace(helper)
print(f'Installed: {target}')
print('Previous bundle and saved sessions were backed up. Reopen Cue.')
