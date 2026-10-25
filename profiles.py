"""Profile paths, child environment and sandbox policy. No Steam launches here."""
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import tempfile
import uuid

ROOT = Path(__file__).resolve().parent
DATA_ROOT = Path(os.environ.get('MSI_DATA_ROOT', str(Path.home()/'Library/Application Support/MacSteam Isolation')))
LIBRARY = Path(os.environ.get('MSI_ISOLATION_LIBRARY', str(ROOT/'build/libmacsteam_isolation.dylib')))
SERVICE = 'com.valvesoftware.steam.ipctool'


def private_directory(path):
    path = Path(path)
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    status = path.lstat()
    if not stat.S_ISDIR(status.st_mode) or status.st_uid != os.getuid() or stat.S_IMODE(status.st_mode) & 0o077:
        raise ValueError('Private profile directory is a symlink, foreign-owned or accessible to others: '+str(path))
    return path


def new_profile(name, base=None, primary=None):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}', name):
        raise ValueError('Use 1–48 letters, digits, underscore or hyphen')
    parent = Path(base) if base else DATA_ROOT/'profiles'
    private_directory(parent)
    path = parent/name
    path.mkdir(mode=0o700, exist_ok=False)
    identity = uuid.uuid4().hex
    home = private_directory(path/'Home')
    private_directory(home/'Library')
    private_directory(home/'Library/Application Support')
    steam = private_directory(home/'Library/Application Support/Steam')
    private_directory(home/'Library/Preferences')
    ipc = private_directory(Path('/private/tmp')/('msi-{}-{}'.format(os.getuid(), identity[:16])))
    source = Path(primary) if primary else Path.home()/'Library/Application Support/Steam'
    profile = {'schema': 2, 'id': identity, 'name': name, 'root': str(path.resolve()), 'home': str(home.resolve()),
               'tmp': str(ipc), 'steam_private': str(steam.resolve()), 'steam_source': str(source.resolve()),
               'app_source': '/Applications/Steam.app', 'app_private': str(path.resolve()/'Steam.app'),
               'primary_home': str(Path.home()), 'mach_service': 'com.macsteam.isolation.'+identity+'.ipctool',
               'steam_launch_enabled': False, 'stage': 'profile_created'}
    save_profile(profile)
    seed_platform_preferences(profile)
    return profile


def seed_platform_preferences(profile):
    # A new home still needs basic OS locale defaults. No Steam/account domains
    # or other user preferences are copied into the profile.
    source=Path.home()/'Library/Preferences/.GlobalPreferences.plist'
    try:original=plistlib.loads(source.read_bytes())
    except (OSError,ValueError,plistlib.InvalidFileException):original={}
    path=Path(profile['home'])/'Library/Preferences/.GlobalPreferences.plist'
    try:values=plistlib.loads(path.read_bytes())
    except (OSError,ValueError,plistlib.InvalidFileException):values={}
    values.setdefault('AppleLanguages',original.get('AppleLanguages') or ['en-US'])
    values.setdefault('AppleLocale',original.get('AppleLocale') or 'en_US')
    write_plist(path,values)


def save_profile(profile):
    path = Path(profile['root'])/'profile.json'
    with open(str(path)+'.new', 'w') as stream:
        json.dump(profile, stream, indent=2)
    os.chmod(str(path)+'.new', 0o600)
    os.replace(str(path)+'.new', str(path))


def load_profile(name):
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}', name):
        raise ValueError('Invalid profile name')
    path = DATA_ROOT/'profiles'/name/'profile.json'
    profile = json.loads(path.read_text())
    if profile.get('schema') != 2 or not re.fullmatch(r'[0-9a-f]{32}', profile.get('id', '')):
        raise ValueError('Profile schema is unsupported; create a new profile')
    if Path(profile['root']).resolve() != path.parent.resolve():
        raise ValueError('Profile path changed; prepare a new profile')
    root = Path(profile['root'])
    expected = {'home':root/'Home', 'steam_private':root/'Home/Library/Application Support/Steam',
                'app_private':root/'Steam.app',
                'tmp':Path('/private/tmp')/('msi-{}-{}'.format(os.getuid(),profile['id'][:16]))}
    for key, value in expected.items():
        if Path(profile[key]) != value:
            raise ValueError('Profile '+key+' path is invalid; create a new profile')
    if profile['mach_service']!='com.macsteam.isolation.'+profile['id']+'.ipctool':
        raise ValueError('Profile helper name is invalid')
    for key in ('root', 'home', 'tmp', 'steam_private'):
        private_directory(profile[key])
    return profile


def ipc_namespace(profile):
    # Each Steam launch gets fresh POSIX IPC names; see begin_ipc_session.
    value = profile.get('ipc_namespace') or profile['id']
    if not re.fullmatch(r'[0-9a-f]{32}', value):
        raise ValueError('Profile IPC name space is invalid')
    return value


def environment(profile):
    env = dict(os.environ)
    env.update(HOME=profile['home'], CFFIXED_USER_HOME=profile['home'], TMPDIR=profile['tmp']+'/',
               DYLD_INSERT_LIBRARIES=str(LIBRARY), MSI_ISOLATION_LIBRARY=str(LIBRARY), MSI_PRIVATE_HOME=profile['home'],
               MSI_PRIMARY_HOME=profile['primary_home'], MSI_STEAM_SOURCE=profile['steam_source'],
               MSI_STEAM_PRIVATE=profile['steam_private'], MSI_APP_SOURCE=profile['app_source'],
               MSI_APP_PRIVATE=profile['app_private'], MSI_IPC_ROOT=profile['tmp'], MSI_NAMESPACE=profile['id'],
               MSI_IPC_NAMESPACE=ipc_namespace(profile), MSI_TRACE='1')
    # No Steam account/session selectors inherited from the primary game.
    for key in ('SteamAppId', 'SteamGameId', 'SteamClientLaunch', 'SteamEnv', 'SteamPath', 'SteamClientDll', 'SteamClientDll64'):
        env.pop(key, None)
    return env


def sandbox_policy(profile):
    quote = lambda s: json.dumps(str(s), ensure_ascii=False)
    protected = [profile['steam_source'], profile['app_source'], str(Path(profile['primary_home'])/'.steam'),
                 str(Path(profile['primary_home'])/'Library/Keychains')]
    paths = ' '.join('(subpath '+quote(p)+')' for p in protected)
    return '''(version 1)
(allow default)
(deny file-read* file-write* %s)
(deny file-read* file-write* (regex "^/private/tmp/steam"))
(deny mach-lookup mach-register (global-name %s))
(deny ipc-posix-shm ipc-posix-sem
    (require-not (require-any
        (ipc-posix-name-regex "^/?ms2_%s_[0-9a-f]+$")
        (ipc-posix-name-regex "^/?(apple[.]|com[.]apple[.])"))))
(deny signal)
(allow signal (target same-sandbox))
(deny appleevent-send)
(deny network-outbound (remote ip "localhost:57343") (remote ip "localhost:57344"))
(deny network-bind (local ip "localhost:57343") (local ip "localhost:57344"))
(deny process-exec (literal "/bin/launchctl") (literal "/usr/bin/killall") (literal "/usr/bin/osascript") (literal "/usr/bin/open"))
''' % (paths, quote(SERVICE), ipc_namespace(profile)[:10])


def guarded_command(profile, arguments, inject=True, libraries=None):
    # macOS removes DYLD variables when starting protected system tools. Set
    # the insertion path after sandbox-exec/env and before the private target.
    prefix = ['/usr/bin/sandbox-exec', '-p', sandbox_policy(profile), '/usr/bin/env']
    if inject:
        prefix.append('DYLD_INSERT_LIBRARIES='+str(libraries or LIBRARY))
    else:
        prefix += ['-u', 'DYLD_INSERT_LIBRARIES']
    return prefix+list(map(str, arguments))


def helper_plist(profile, executable, arguments=(), extra_environment=None):
    env = environment(profile)
    keys = [key for key in env if key.startswith('MSI_') or key in ('HOME', 'CFFIXED_USER_HOME', 'TMPDIR', 'DYLD_INSERT_LIBRARIES')]
    values = {key: env[key] for key in keys}
    values.update(extra_environment or {})
    return {'Label': profile['mach_service'], 'ProgramArguments': guarded_command(profile, [executable]+list(arguments)),
            'MachServices': {profile['mach_service']: True}, 'EnvironmentVariables': values,
            'RunAtLoad': False, 'KeepAlive': False, 'ProcessType': 'Interactive',
            'StandardOutPath': str(Path(profile['root'])/'helper.stdout.log'),
            'StandardErrorPath': str(Path(profile['root'])/'helper.stderr.log')}


def write_plist(path, value):
    path = Path(path)
    path.write_bytes(plistlib.dumps(value));path.chmod(0o600)
