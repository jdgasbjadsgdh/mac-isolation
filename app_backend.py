"""Native-app backend. Only explicit launch/stop commands start or close apps."""
import argparse
import configparser
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import startup_guard
import secrets

from profiles import (DATA_ROOT, LIBRARY, new_profile, load_profile, save_profile,
                      private_directory, environment, guarded_command, helper_plist, write_plist,seed_platform_preferences)

GAME_SHA = '8ab9adf4a5900a18532f3403bd07f9515fb59f4afbc5e8ebdb795aeeaf698d57'
MAC_SBPE = Path.home()/'Downloads/SBPE-Mac-Windows-Parity'
KEYCHAIN_SETUP=Path(__file__).resolve().parent/'keychain_setup'
if not KEYCHAIN_SETUP.is_file():KEYCHAIN_SETUP=Path(__file__).resolve().parent/'build/keychain_setup'
LIBC=ctypes.CDLL('/usr/lib/libSystem.B.dylib',use_errno=True)
LIBC.sem_unlink.argtypes=LIBC.shm_unlink.argtypes=[ctypes.c_char_p]
LIBC.sem_unlink.restype=LIBC.shm_unlink.restype=ctypes.c_int


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def checked(command, timeout=120):
    result = subprocess.run(list(map(str, command)), text=True, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or 'Command failed: '+str(command[0]))
    return result


def clone_tree(source, destination):
    source, destination = Path(source), Path(destination)
    if destination.exists():
        raise ValueError('A prepared copy already exists: '+str(destination))
    temporary = destination.with_name(destination.name+'.preparing')
    if temporary.exists():
        raise ValueError('An incomplete preparation exists. Open the profile folder to inspect it: '+str(temporary))
    result = subprocess.run(['/bin/cp', '-cR', str(source), str(temporary)], capture_output=True, text=True)
    if result.returncode:
        if temporary.exists():shutil.rmtree(temporary)
        shutil.copytree(str(source), str(temporary), symlinks=True)
    # Reject bundle links that could read/write another installed Steam copy.
    for path in temporary.rglob('*'):
        if path.is_symlink():
            target = path.resolve()
            if temporary.resolve() not in target.parents:
                raise ValueError('Copied bundle has an external link: '+str(path.relative_to(temporary)))
    os.replace(str(temporary), str(destination))


def slug(label):
    result = re.sub(r'[^a-z0-9_-]+', '-', label.strip().lower()).strip('-')
    if not result or len(result)>48:raise ValueError('Use a shorter profile name with letters or numbers.')
    return result


def create(label):
    private_directory(DATA_ROOT)
    profile = new_profile(slug(label))
    profile['display_name'] = label.strip()
    save_profile(profile)
    return summary(profile)


def process_paths():
    result = subprocess.run(['/bin/ps', '-A', '-o', 'pid='], capture_output=True, text=True, check=True)
    proc = ctypes.CDLL('/usr/lib/libproc.dylib')
    proc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    proc.proc_pidpath.restype = ctypes.c_int
    paths = []
    for raw in result.stdout.split():
        pid = int(raw);buffer = ctypes.create_string_buffer(4096)
        if proc.proc_pidpath(pid, buffer, len(buffer)) > 0:
            paths.append((pid, os.fsdecode(buffer.value)))
    return paths


def owned_processes(profile, paths=None):
    root = Path(profile['root']).resolve()
    result = []
    for pid, value in paths if paths is not None else process_paths():
        path = Path(value)
        if root in path.parents:
            result.append({'pid': pid, 'path': value, 'game': path.name == 'mvmmoclient'})
    return result


def summary(profile, paths=None):
    processes = owned_processes(profile, paths)
    startup=startup_guard.read(profile)
    steam_running=any(Path(p['path']).name=='steam_osx' for p in processes)
    startup_note=startup.get('reason','')
    if startup.get('state')=='passed' and not steam_running:
        startup_note='Last startup check passed. Start Steam to sign in.'
    return {'id': profile['id'], 'name': profile['name'], 'display_name': profile.get('display_name',profile['name']),
            'root': profile['root'], 'stage': profile.get('stage','profile_created'),
            'prepared': profile.get('stage')=='prepared', 'game_prepared': bool(profile.get('game')),
            'startup_state':startup.get('state',''), 'startup_note':startup_note,
            'process_count':len(processes),
            'steam_running': steam_running, 'game_running': any(p['game'] for p in processes),
            'processes': processes, 'last_error': profile.get('last_error','') or profile.get('game_prepare_note','')}


def list_profiles():
    profiles = [];paths = process_paths()
    parent = DATA_ROOT/'profiles'
    if parent.exists():
        for path in sorted(parent.iterdir()):
            if path.is_dir() and (path/'profile.json').exists():
                try:profiles.append(summary(load_profile(path.name), paths))
                except Exception as error:profiles.append({'id':path.name,'name':path.name,'display_name':path.name,'stage':'error','root':str(path),'prepared':False,'game_prepared':False,'steam_running':False,'game_running':False,'last_error':str(error),'processes':[],'process_count':0})
    pause=DATA_ROOT/'client-testing-paused.json'
    pause_reason=json.loads(pause.read_text()).get('reason','Steam startup testing is paused.') if pause.is_file() else None
    return {'profiles': profiles, 'data_root': str(DATA_ROOT), 'client_validation': 'pending', 'launch_pause_reason':pause_reason,
            'isolation_library_exists': LIBRARY.is_file(), 'profile_limit': None}


def prepare_profile(name):
    profile = load_profile(name)
    if owned_processes(profile):raise ValueError('Stop this profile before preparing its files.')
    if not LIBRARY.is_file():raise ValueError('The isolation library is missing. Reinstall the application.')
    source = Path(profile['steam_source'])/'Steam.AppBundle/Steam'
    if not (source/'Contents/MacOS/steam_osx').is_file():raise ValueError('Install and open the normal Steam application once before preparing a profile.')
    destination = Path(profile['app_private'])
    original_hash = digest(source/'Contents/MacOS/steam_osx')
    profile['stage'] = 'preparing';save_profile(profile)
    try:
        seed_platform_preferences(profile)
        prepare_keychain(profile)
        # Preserve Valve's code and metadata byte for byte. Re-signing changes
        # the sizes in Steam's installed manifest and triggers its repair loop.
        # The installed build has no hardened-runtime/library-validation flags,
        # so insertion does not require changing these vendor signatures.
        if destination.exists() and profile.get('preparation_mode') != 'vendor-code-v1':
            previous=destination.with_name('Steam.before-vendor-preservation-'+str(time.time_ns()))
            os.replace(str(destination),str(previous))
        if not destination.exists():clone_tree(source,destination)
        private_main=destination/'Contents/MacOS/steam_osx'
        if digest(private_main)!=original_hash:
            previous=destination.with_name('Steam.before-reprepare-'+str(time.time_ns()))
            os.replace(str(destination),str(previous));clone_tree(source,destination)
        profile['preparation_mode']='vendor-code-v1'
        install = Path(profile['steam_private'])
        alias_parent = private_directory(install/'Steam.AppBundle');alias = alias_parent/'Steam'
        if not alias.exists():alias.symlink_to(os.path.relpath(str(destination),str(alias_parent)))
        if alias.resolve()!=destination.resolve():raise ValueError('Private install alias points to another app.')
        apply_private_identity(profile)
        helper = destination/'Contents/MacOS/ipcserver'
        write_plist(Path(profile['root'])/'private-helper.plist',helper_plist(profile,helper))
        if digest(source/'Contents/MacOS/steam_osx')!=original_hash:raise RuntimeError('Source Steam changed during preparation; repeat preparation after its update finishes.')
        profile.update(stage='prepared',steam_launch_enabled=True,last_error='',
                       game_prepare_note='',
                       library_sha256=digest(LIBRARY),source_steam_sha256=original_hash,
                       prepared_steam_sha256=digest(destination/'Contents/MacOS/steam_osx'),live_validation='pending')
        save_profile(profile)
        try:prepare_game(profile)
        except Exception as error:
            profile['game_prepare_note']=str(error);save_profile(profile)
        return summary(profile)
    except Exception as error:
        profile.update(stage='preparation_failed',last_error=str(error));save_profile(profile);raise


LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'


def apply_private_identity(profile):
    """Give the private copy its own app identity.

    Valve's Info.plist declares com.valvesoftware.steam with
    LSMultipleInstancesProhibited, so macOS treated a private client as a
    forbidden second instance of the user's Steam and moved focus between the
    two. Only Contents/Info.plist changes; Steam verifies Contents/MacOS."""
    root=Path(profile['app_private']);plist=root/'Contents/Info.plist'
    if plist.is_symlink() or not plist.is_file():raise ValueError('The private Steam copy is incomplete. Prepare this profile again.')
    info=plistlib.loads(plist.read_bytes())
    label='Steam ('+profile.get('display_name',profile['name'])+')'
    wanted=dict(info,CFBundleIdentifier='com.macsteam.isolation.'+profile['id']+'.steam',CFBundleName=label,CFBundleDisplayName=label)
    # Links such as steam:// must keep opening the user's real Steam.
    for key in ('CFBundleURLTypes','CFBundleDocumentTypes','UTExportedTypeDeclarations','UTImportedTypeDeclarations','LSMultipleInstancesProhibited'):
        wanted.pop(key,None)
    changed=wanted!=info
    if changed:
        temporary=plist.with_name('Info.plist.next');temporary.write_bytes(plistlib.dumps(wanted));os.replace(str(temporary),str(plist))
    changed=restore_helper(profile) or changed
    if changed:refresh_launch_services(root)
    return changed


HELPER_ID=b'com.valvesoftware.steam.helper'


def restore_helper(profile):
    """Undo the 0.1.2 test build's helper rename.

    Valve's helper is code-signed with its Info.plist, and macOS kills a helper
    whose Info.plist was changed (exit -9 at launch), so its ID must stay."""
    plist=Path(profile['app_private'])/'Contents/MacOS/Frameworks/Steam Helper.app/Contents/Info.plist'
    if plist.is_symlink() or not plist.is_file():raise ValueError('The private Steam copy is incomplete. Prepare this profile again.')
    data=plist.read_bytes()
    pattern=re.compile(rb'(<key>CFBundleIdentifier</key>\s*<string>)msi\.steamhelper\.[0-9a-f]{14}(</string>)')
    if not pattern.search(data):return False
    temporary=plist.with_name('Info.plist.next');temporary.write_bytes(pattern.sub(lambda m:m[1]+HELPER_ID+m[2],data,count=1))
    os.replace(str(temporary),str(plist))
    return True


def refresh_launch_services(bundle):
    # Re-register now, so the old identity and steam:// claim go immediately.
    for path in (bundle,Path(bundle)/'Contents/MacOS/Frameworks/Steam Helper.app'):
        subprocess.run([LSREGISTER,'-f',str(path)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=60)


def prepare_game(profile):
    if not (MAC_SBPE/'sbpe-mac.dylib').is_file():raise ValueError('Mac SBPE was not found in Downloads/SBPE-Mac-Windows-Parity.')
    game_source=Path(profile['steam_source'])/'steamapps/common/StarBreak'
    executable=game_source/'MVMMOClient.app/Contents/MacOS/mvmmoclient'
    if not executable.is_file():raise ValueError('Install StarBreak through the main Steam account first.')
    if digest(executable)!=GAME_SHA:raise ValueError('The installed StarBreak build differs from the supported SBPE build.')
    private_game=Path(profile['steam_private'])/'steamapps/common/StarBreak'
    private_game.parent.mkdir(parents=True,exist_ok=True)
    if not private_game.exists():clone_tree(game_source,private_game)
    game=private_game/'MVMMOClient.app';plist=game/'Contents/Info.plist';info=plistlib.loads(plist.read_bytes())
    info.update(CFBundleIdentifier='com.macsteam.isolation.'+profile['id']+'.starbreak',NSHighResolutionCapable=True)
    plist.write_bytes(plistlib.dumps(info))
    sbpe=private_directory(Path(profile['root'])/'SBPE')
    shutil.copy2(str(MAC_SBPE/'sbpe-mac.dylib'),str(sbpe/'sbpe-mac.dylib'))
    if not (sbpe/'config.ini').exists():
        config=configparser.ConfigParser(interpolation=None);config.optionxform=str;config.read(str(MAC_SBPE/'config.ini'))
        if config.has_section('plugin_efc_capture'):config['plugin_efc_capture']['enabled']='no'
        with (sbpe/'config.ini').open('w') as stream:config.write(stream)
    if not (sbpe/'data').exists():shutil.copytree(str(MAC_SBPE/'data'),str(sbpe/'data'))
    write_game_manifest(profile)
    profile['game']={'executable':str(game/'Contents/MacOS/mvmmoclient'),'cwd':str(game/'Contents/MacOS'),
                     'sbpe_root':str(sbpe),'game_sha256':GAME_SHA,'sbpe_sha256':digest(sbpe/'sbpe-mac.dylib')}
    save_profile(profile)


def refresh_sbpe(profile):
    """Run the current Mac SBPE build in this profile (settings stay its own)."""
    current=MAC_SBPE/'sbpe-mac.dylib';target=Path(profile['game']['sbpe_root'])/'sbpe-mac.dylib'
    if not current.is_file() or (target.is_file() and digest(target)==digest(current)):return False
    temporary=target.with_name(target.name+'.next');shutil.copy2(str(current),str(temporary));os.replace(str(temporary),str(target))
    profile['game']['sbpe_sha256']=digest(target);save_profile(profile)
    return True


def write_game_manifest(profile):
    """Install record for the private StarBreak copy.

    Steam rejected the earlier minimal manifest ("Loaded 0 apps"), so the
    profile's account saw StarBreak as not installed. Copy the installed
    manifest, without the user's account (LastOwner) or play time."""
    target=Path(profile['steam_private'])/'steamapps/appmanifest_420790.acf'
    if target.is_file() and '"Universe"' in target.read_text(errors='replace'):return False
    source=Path(profile['steam_source'])/'steamapps/appmanifest_420790.acf'
    if not source.is_file():raise ValueError('Install StarBreak through the main Steam account first.')
    text=re.sub(r'^[ \t]*"(LastOwner|LastPlayed)"[ \t]+"[^"]*"[ \t]*\n','',source.read_text(),flags=re.M)
    if not re.search(r'"appid"\s+"420790"',text):
        raise ValueError('The installed StarBreak manifest is unexpected. Repair StarBreak in the main Steam.')
    target.parent.mkdir(parents=True,exist_ok=True)
    temporary=target.with_name(target.name+'.next');temporary.write_text(text);os.replace(str(temporary),str(target))
    return True


def prepare_keychain(profile):
    if not KEYCHAIN_SETUP.is_file():raise ValueError('The private keychain helper is missing. Reinstall the application.')
    directory=private_directory(Path(profile['home'])/'Library/Keychains')
    secret=directory/'unlock.secret'
    try:
        fd=os.open(str(secret),os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    except FileExistsError:pass
    else:
        with os.fdopen(fd,'w') as stream:stream.write(secrets.token_hex(32))
    result=subprocess.run(
        guarded_command(profile,[KEYCHAIN_SETUP]),env=environment(profile),capture_output=True,text=True,timeout=20)
    if result.returncode:
        raise ValueError('Private keychain setup failed. '+result.stdout.strip())
    value=json.loads(result.stdout)
    if value['status'] or Path(profile['home']) not in Path(value['path']).parents:
        raise ValueError('Private keychain did not resolve inside this profile.')
    profile['keychain']={'path':value['path'],'initialized':True}
    save_profile(profile)
    return value


def validate_prepared(profile):
    root=Path(profile['root']).resolve()
    if Path(profile['app_private']).resolve()!=root/'Steam.app':raise ValueError('Private app path is invalid.')
    if profile.get('stage')!='prepared' or not profile.get('steam_launch_enabled'):raise ValueError('Prepare this profile first.')
    if profile.get('preparation_mode')!='vendor-code-v1':raise ValueError('Prepare this profile again to install the Steam update-loop fix.')
    executable=Path(profile['app_private'])/'Contents/MacOS/steam_osx'
    if digest(executable)!=profile.get('prepared_steam_sha256'):raise ValueError('The private Steam copy changed. Prepare it again before launching.')
    if profile['mach_service']!='com.macsteam.isolation.'+profile['id']+'.ipctool':raise ValueError('Private helper name is invalid.')
    return executable


def release_ipc_names(profile):
    """Unlink POSIX semaphores/shared memory recorded by earlier sessions.

    The kernel keeps these after a client is killed; a held lock left behind
    stalls the next client. Call only while none of the profile runs."""
    released=0
    for record in Path(profile['tmp']).glob('ipc-*.names'):
        space=record.name[4:-6]
        if not re.fullmatch(r'[0-9a-f]{10}',space) or record.is_symlink():continue
        try:lines=record.read_text().splitlines()
        except OSError:continue
        for line in set(lines):
            kind,_,name=line.partition(' ')
            # Only this record's own /ms2_<space>_ names, never another profile's.
            if kind not in ('s','m') or not re.fullmatch(r'/ms2_'+space+r'_[0-9a-f]{12}',name):continue
            if (LIBC.sem_unlink if kind=='s' else LIBC.shm_unlink)(name.encode())==0:released+=1
        record.unlink()
    return released


def begin_ipc_session(profile):
    if owned_processes(profile):raise ValueError('Stop this profile before starting a new Steam session.')
    released=release_ipc_names(profile)
    profile['ipc_namespace']=secrets.token_hex(16)
    save_profile(profile)
    return released


def clear_leftovers(name):
    """Stop helpers left by a client that exited on its own, so the next launch
    starts a fresh helper with the new IPC name space."""
    profile=load_profile(name)
    for force in (False,True):
        if not owned_processes(profile):break
        _stop_profile(name,force=force)
        deadline=time.monotonic()+3
        while owned_processes(profile) and time.monotonic()<deadline:time.sleep(.2)
    if owned_processes(profile):raise RuntimeError('Old processes from this profile did not exit. Use Stop profile and try again.')
    if private_helper_loaded(profile):checked(['/bin/launchctl','bootout',helper_domain(profile)])


def bootstrap_helper(profile):
    # launchd can briefly refuse a label that was just booted out.
    for attempt in range(10):
        result=subprocess.run(['/bin/launchctl','bootstrap','gui/{}'.format(os.getuid()),str(Path(profile['root'])/'private-helper.plist')],
                              capture_output=True,text=True,timeout=20)
        if result.returncode==0:return
        time.sleep(.5)
    raise RuntimeError(result.stderr.strip() or 'The private Steam helper could not be registered.')


def helper_domain(profile):return 'gui/{}/{}'.format(os.getuid(),profile['mach_service'])


def private_helper_loaded(profile):
    return subprocess.run(['/bin/launchctl','print',helper_domain(profile)],capture_output=True,timeout=10).returncode==0


def launch_steam(name):
    profile=load_profile(name)
    with startup_guard.lock(profile):return _launch_steam(name)


def _launch_steam(name):
    pause=DATA_ROOT/'client-testing-paused.json'
    if pause.is_file():
        raise ValueError(json.loads(pause.read_text()).get('reason','Steam startup tests are paused for compatibility repairs.'))
    profile=load_profile(name);executable=validate_prepared(profile)
    processes=owned_processes(profile)
    if any(Path(p['path']).name=='steam_osx' for p in processes):raise ValueError('This Steam profile is already running.')
    if any(p['game'] for p in processes):raise ValueError('StarBreak from this profile is still running. Stop the profile first.')
    clear_leftovers(name)
    profile=load_profile(name)
    apply_private_identity(profile)
    if profile.get('game'):write_game_manifest(profile)
    prepare_keychain(profile)
    begin_ipc_session(profile)
    # The helper environment carries this launch's IPC name space and the
    # current library path, so it is rewritten for every launch.
    profile['library_sha256']=digest(LIBRARY)
    write_plist(Path(profile['root'])/'private-helper.plist',helper_plist(profile,Path(profile['app_private'])/'Contents/MacOS/ipcserver'))
    save_profile(profile)
    bootstrap_helper(profile)
    log=Path(profile['root'])/'steam.log'
    log_paths=('steam.log','Home/Library/Application Support/Steam/logs/cef_log.txt',
               'Home/Library/Application Support/Steam/logs/webhelper.txt')
    offsets={p:(Path(profile['root'])/p).stat().st_size if (Path(profile['root'])/p).exists() else 0 for p in log_paths}
    startup=startup_guard.begin(profile,offsets)
    with log.open('ab',buffering=0) as output:
        # Chromium cannot install a second Seatbelt sandbox inside our kernel
        # profile. This option applies only to this private Steam launch.
        command=guarded_command(profile,[executable,'-nobootstrapperupdate','-no-cef-sandbox'])
        process=subprocess.Popen(command,env=environment(profile),cwd=str(executable.parent),stdout=output,stderr=output,start_new_session=True)
    profile['last_launch_pid']=process.pid;save_profile(profile)
    try:
        subprocess.Popen(['/usr/bin/python3',str(Path(__file__).with_name('startup_guard.py')),name,startup['token']],
                         stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
    except Exception:
        _stop_profile(name);raise RuntimeError('The startup monitor could not start; the private client was stopped.')
    return {'pid':process.pid,'log':str(log),'validation':'Waiting up to {} seconds for the Steam sign-in window.'.format(startup_guard.TIMEOUT)}


def launch_game(name):
    profile=load_profile(name);validate_prepared(profile)
    processes=owned_processes(profile)
    if any(p['game'] for p in processes):raise ValueError('StarBreak is already running in this profile.')
    if not any(Path(p['path']).name=='steam_osx' for p in processes):raise ValueError('Start this Steam profile and sign in first.')
    if startup_guard.read(profile).get('state')!='passed':raise ValueError('Wait for this Steam profile’s startup check to pass before launching StarBreak.')
    if not profile.get('game'):prepare_game(profile)
    game=profile['game'];executable=Path(game['executable']);sbpe=Path(game['sbpe_root'])
    refresh_sbpe(profile)
    if digest(executable)!=GAME_SHA or digest(sbpe/'sbpe-mac.dylib')!=game['sbpe_sha256']:raise ValueError('The game or SBPE library changed. Prepare this profile again.')
    libraries=str(LIBRARY)+':'+str(sbpe/'sbpe-mac.dylib')
    env=environment(profile);env.update(SBPE_ROOT=str(sbpe),SteamAppId='420790',SteamGameId='420790',SDL_VIDEO_HIGHDPI_DISABLED='0',DYLD_INSERT_LIBRARIES=libraries)
    with (Path(profile['root'])/'starbreak.log').open('ab',buffering=0) as output:
        process=subprocess.Popen(guarded_command(profile,[executable],libraries=libraries),env=env,cwd=game['cwd'],stdout=output,stderr=output,start_new_session=True)
    return {'pid':process.pid,'log':str(Path(profile['root'])/'starbreak.log'),'sbpe_root':str(sbpe)}


def stop_profile(name, force=False, expected_startup_token=None):
    profile=load_profile(name)
    with startup_guard.lock(profile):return _stop_profile(name,force,expected_startup_token)


def request_steam_exit(profile):
    # Steam ignores SIGTERM, and killing its helpers makes it respawn windows.
    # Its own -shutdown reaches only the client in this profile's IPC space.
    executable=Path(profile['app_private'])/'Contents/MacOS/steam_osx'
    try:
        subprocess.run(guarded_command(profile,[executable,'-shutdown']),env=environment(profile),cwd=str(executable.parent),
                       stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
    except (OSError,subprocess.TimeoutExpired):pass


def wait_for_exit(profile,seconds,keep_helper=False):
    deadline=time.monotonic()+seconds
    while True:
        remaining=[p for p in owned_processes(profile) if not (keep_helper and Path(p['path']).name=='ipcserver')]
        if not remaining or time.monotonic()>=deadline:return remaining
        time.sleep(.25)


def signal_owned(profile,number):
    stopped=[]
    for process in owned_processes(profile):
        # Recheck identity immediately before signalling: never use an old PID
        # record to stop the user's primary Steam or another application.
        current={p['pid']:p for p in owned_processes(profile)}
        if process['pid'] in current:
            try:os.kill(process['pid'],number);stopped.append(process['pid'])
            except ProcessLookupError:pass
    return stopped


def _stop_profile(name, force=False, expected_startup_token=None):
    profile=load_profile(name)
    status=startup_guard.read(profile)
    if expected_startup_token is not None:
        if status.get('token')!=expected_startup_token or any(p['game'] for p in owned_processes(profile)):
            return {'stopped_pids':[]}
    if status.get('state')=='checking':
        status.update(state='cancelled',reason='Startup check stopped.');startup_guard.write(profile,status)
    # A user stop lets Steam quit cleanly first, keeping its IPC helper alive
    # until then. A failed startup check skips straight to signals.
    if not force and expected_startup_token is None and any(Path(p['path']).name=='steam_osx' for p in owned_processes(profile)):
        request_steam_exit(profile);wait_for_exit(profile,15,keep_helper=True)
    stopped=signal_owned(profile,signal.SIGKILL if force else signal.SIGTERM)
    for attempt in range(3):
        if not stopped or not wait_for_exit(profile,1 if force or attempt else 3):break
        stopped+=[pid for pid in signal_owned(profile,signal.SIGKILL) if pid not in stopped]
    if private_helper_loaded(profile):checked(['/bin/launchctl','bootout',helper_domain(profile)])
    return {'stopped_pids':stopped}


def main():
    parser=argparse.ArgumentParser();parser.add_argument('command',choices=['list','create','prepare','launch-steam','launch-game','stop','prepare-game']);parser.add_argument('name',nargs='?');args=parser.parse_args()
    try:
        if args.command=='list':value=list_profiles()
        elif args.command=='create':value=create(args.name or 'Steam 1')
        elif args.command=='prepare':value=prepare_profile(args.name)
        elif args.command=='launch-steam':value=launch_steam(args.name)
        elif args.command=='launch-game':value=launch_game(args.name)
        elif args.command=='stop':value=stop_profile(args.name)
        else:
            profile=load_profile(args.name);prepare_game(profile);value=summary(profile)
        print(json.dumps({'ok':True,'result':value}))
    except Exception as error:
        print(json.dumps({'ok':False,'error':str(error)}));return 1
    return 0


if __name__=='__main__':sys.exit(main())
