"""Bounded startup check for one explicitly launched private Steam client."""
import json
import os
from pathlib import Path
import sys
import time
import uuid
import fcntl
import re
from contextlib import contextmanager

TIMEOUT=60


@contextmanager
def lock(profile):
    fd=os.open(str(Path(profile['root'])/'manager.lock'),os.O_CREAT|os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX);yield
    finally:
        fcntl.flock(fd,fcntl.LOCK_UN);os.close(fd)


def read(profile):
    try:return json.loads((Path(profile['root'])/'startup-check.json').read_text())
    except (OSError,ValueError):return {}


def write(profile,value):
    path=Path(profile['root'])/'startup-check.json'
    temporary=path.with_name(path.name+'.'+uuid.uuid4().hex+'.next')
    temporary.write_text(json.dumps(value,indent=2)+'\n');temporary.chmod(0o600)
    os.replace(str(temporary),str(path))


def begin(profile,offsets):
    status={'token':uuid.uuid4().hex,'state':'checking','started_at':time.time(),
            'reason':'Checking Steam startup…','offsets':offsets}
    write(profile,status);return status


def failure(text):
    text=text.lower()
    if 'sandbox initialization failed' in text or 'failed to initialize the sandbox' in text:
        return 'Steam’s web UI could not initialize its sandbox.'
    if "gpu process isn't usable" in text or text.count('gpu process exited unexpectedly')>=3:
        return 'Steam’s web UI repeatedly restarted its graphics process.'
    if 'bmainloop appears to have stalled' in text:
        return 'Steam’s main engine stalled before the sign-in window was ready.'
    return None


def desktop_ready(text):
    # A hidden 0x0 Shared JS Context is not a login window. Require a real
    # desktop/login browser and completion of that same browser's first load.
    expression=r'(SP Desktop(?:LoginWindow)?_uid\d+): AfterCreated[^\n]*?\b(\d+)x(\d+)'
    for match in re.finditer(expression,text):
        if int(match[2])<300 or int(match[3])<200:continue
        loaded=re.escape(match[1])+r"(?:-'[^'\n]*')?: STARTUP (?:LoadEnd|FirstPaint)"
        if re.search(loaded,text[match.end():]):return True
    return False


def monitor(name,token):
    import app_backend as app
    profile=app.load_profile(name);initial=read(profile)
    if initial.get('token')!=token or initial.get('state')!='checking':return
    offsets=initial['offsets'];start=time.monotonic();output=''
    while time.monotonic()-start<TIMEOUT:
        status=read(profile)
        if status.get('token')!=token or status.get('state')!='checking':return
        for relative,offset in list(offsets.items()):
            path=Path(profile['root'])/relative
            try:
                size=path.stat().st_size
                with path.open('rb') as stream:
                    stream.seek(offset if size>=offset else 0)
                    chunk=stream.read(262144);offsets[relative]=stream.tell()
                output=(output+chunk.decode('utf-8','replace'))[-524288:]
            except OSError:pass
        processes=app.owned_processes(profile)
        reason=failure(output)
        main=any(Path(p['path']).name=='steam_osx' for p in processes)
        helper=any(Path(p['path']).name=='Steam Helper' for p in processes)
        if not main and time.monotonic()-start>3:
            reason=reason or 'Steam exited before its sign-in window appeared.'
        if reason:
            fail(app,profile,token,reason);return
        if main and helper and desktop_ready(output):
            with lock(profile):
                status=read(profile)
                if status.get('token')==token and status.get('state')=='checking':
                    status.update(state='passed',reason='Steam’s sign-in window is ready. Sign in to this profile’s account.')
                    write(profile,status)
            return
        time.sleep(.5)
    fail(app,profile,token,'Steam did not show its sign-in or desktop window within {} seconds.'.format(TIMEOUT))


def fail(app,profile,token,reason):
    status=read(profile)
    if status.get('token')!=token or status.get('state')!='checking':return
    # Launch game is blocked while checking. Still recheck before automatic
    # cleanup, so a manually launched game is never stopped by this monitor.
    if not any(p['game'] for p in app.owned_processes(profile)):
        app.stop_profile(profile['name'],expected_startup_token=token)
        time.sleep(.5)
        if not any(p['game'] for p in app.owned_processes(profile)):
            app.stop_profile(profile['name'],force=True,expected_startup_token=token)
    status.update(state='failed',reason=reason+' Startup stopped; see the profile logs.')
    with lock(profile):
        current=read(profile)
        if current.get('token')==token:write(profile,status)


if __name__=='__main__':monitor(sys.argv[1],sys.argv[2])
