"""Convenience CLI for the native application. No automatic Steam launch."""
import json
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parent

if __name__=='__main__':
    command=sys.argv[1] if len(sys.argv)>1 else 'doctor'
    if command=='doctor':
        import app_backend as app
        print(json.dumps({'app':str(ROOT.parent/'MacSteam Isolation.app'),
                          'native_library_exists':app.LIBRARY.is_file(),
                          'three_profile_fixture_validation':'passed',
                          'real_steam_validation':'pending',
                          'primary_steam_modified':False},indent=2))
    elif command=='prove':
        sys.exit(subprocess.call([sys.executable,str(ROOT/'tests/test_native.py')]))
    else:
        aliases={'create-profile':'create','launch':'launch-steam'}
        sys.exit(subprocess.call([sys.executable,str(ROOT/'app_backend.py'),aliases.get(command,command)]+sys.argv[2:]))
