"""Disposable profile keychains only; no Steam launches or host-default changes."""
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
from profiles import new_profile,private_directory,guarded_command,environment
import app_backend as app


def host_settings():
    return {verb:subprocess.run(['/usr/bin/security',verb,'-d','user'],capture_output=True,text=True,check=True,timeout=10).stdout
            for verb in ('default-keychain','list-keychains')}


class KeychainTests(unittest.TestCase):
    def setUp(self):
        self.before=host_settings()
        self.temp=tempfile.TemporaryDirectory(prefix='msi-keychain-tests-')
        self.profiles=[new_profile(name,Path(self.temp.name)/'profiles') for name in ('A','B','C')]

    def tearDown(self):
        try:self.assertEqual(host_settings(),self.before,'Host keychain defaults/search list changed')
        finally:
            for profile in self.profiles:shutil.rmtree(profile['tmp'])
            self.temp.cleanup()

    def test_private_defaults_and_null_keychain_password_operations(self):
        paths=[]
        for profile in self.profiles:
            first=app.prepare_keychain(profile)
            password=(Path(profile['home'])/'Library/Keychains/unlock.secret').read_bytes()
            self.assertEqual(len(password),64)
            for _ in range(2):
                result=subprocess.run(guarded_command(profile,[ROOT/'build/keychain_setup','probe']),
                                      env=environment(profile),capture_output=True,text=True,timeout=20)
                self.assertEqual(result.returncode,0,result.stderr+result.stdout)
                value=json.loads(result.stdout);self.assertEqual(value['status'],0)
                self.assertEqual(Path(value['path']),Path(first['path']))
            app.prepare_keychain(profile)
            self.assertEqual((Path(profile['home'])/'Library/Keychains/unlock.secret').read_bytes(),password)
            paths.append(first['path'])
        self.assertEqual(len(set(paths)),3)

    def test_missing_injection_and_insecure_secret_fail_without_dialogs(self):
        profile=self.profiles[0]
        directory=private_directory(Path(profile['home'])/'Library/Keychains')
        secret=directory/'unlock.secret';secret.write_text(secrets.token_hex(32));secret.chmod(0o644)
        result=subprocess.run(guarded_command(profile,[ROOT/'build/keychain_setup']),env=environment(profile),capture_output=True,timeout=10)
        self.assertEqual(result.returncode,3)
        secret.chmod(0o600)
        result=subprocess.run(guarded_command(profile,[ROOT/'build/keychain_setup'],inject=False),env=environment(profile),capture_output=True,timeout=10)
        self.assertEqual(result.returncode,2)

    def test_rosetta_uses_the_same_private_keychain(self):
        profile=self.profiles[0];value=app.prepare_keychain(profile)
        result=subprocess.run(guarded_command(profile,['/usr/bin/arch','-x86_64','/usr/bin/env',
                              'DYLD_INSERT_LIBRARIES='+str(app.LIBRARY),ROOT/'build/keychain_setup','probe']),
                              env=environment(profile),text=True,capture_output=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr+result.stdout)
        self.assertEqual(json.loads(result.stdout)['path'],value['path'])


if __name__=='__main__':unittest.main(verbosity=2)
