"""Real disposable native processes; never launches Steam or StarBreak."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1];sys.path.insert(0,str(ROOT))
import app_backend as app
import profiles
import startup_guard


class StartupGuardTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='msi-startup-guard-')
        self.base=Path(self.temp.name)
        self.patches=[patch.object(app,'DATA_ROOT',self.base),patch.object(profiles,'DATA_ROOT',self.base)]
        for p in self.patches:p.start()
        self.profiles=[profiles.new_profile(n) for n in ('A','B')];self.children=[]
        for profile in self.profiles:
            exe=Path(profile['app_private'])/'Contents/MacOS/steam_osx';exe.parent.mkdir(parents=True)
            shutil.copy2(ROOT/'build/native_fixture',exe)
            child=subprocess.Popen(profiles.guarded_command(profile,[exe,'wait']),env=profiles.environment(profile),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            self.children.append(child);self.assertEqual(child.stdout.readline().strip(),'READY')

    def tearDown(self):
        for profile in self.profiles:app.stop_profile(profile['name'],force=True)
        for child in self.children:
            child.wait(timeout=10);child.stdout.close();child.stderr.close()
        for profile in self.profiles:shutil.rmtree(profile['tmp'])
        for p in reversed(self.patches):p.stop()
        self.temp.cleanup()

    def test_repeated_ui_failure_stops_only_its_own_live_processes(self):
        a,b=self.profiles
        status=startup_guard.begin(a,{'steam.log':0})
        (Path(a['root'])/'steam.log').write_text('GPU process exited unexpectedly\n'*3)
        startup_guard.monitor(a['name'],status['token'])
        self.children[0].wait(timeout=5)
        self.assertIsNotNone(self.children[0].poll())
        self.assertIsNone(self.children[1].poll())
        self.assertEqual(startup_guard.read(a)['state'],'failed')

    def test_stale_monitor_leaves_a_new_generation_running(self):
        profile=self.profiles[0]
        old=startup_guard.begin(profile,{'steam.log':0})
        new=startup_guard.begin(profile,{'steam.log':0})
        startup_guard.monitor(profile['name'],old['token'])
        self.assertIsNone(self.children[0].poll())
        self.assertEqual(startup_guard.read(profile)['token'],new['token'])


if __name__=='__main__':unittest.main(verbosity=2)
