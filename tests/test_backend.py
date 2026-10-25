"""Launch safety checks. Steam/game launches are mocked, never executed."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import app_backend as app
import profiles
import startup_guard


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='msi-manager-tests-')
        self.base=Path(self.temp.name)
        self.library=self.base/'isolation.dylib';self.library.write_bytes(b'fixture library')
        self.patches=[patch.object(profiles,'DATA_ROOT',self.base),patch.object(app,'DATA_ROOT',self.base),
                      patch.object(profiles,'LIBRARY',self.library),patch.object(app,'LIBRARY',self.library),
                      patch.object(app,'prepare_keychain',return_value={'status':0}),
                      patch.object(app,'refresh_launch_services')]
        for item in self.patches:item.start()
        self.profile=profiles.new_profile('test')
        self.executable=Path(self.profile['app_private'])/'Contents/MacOS/steam_osx'
        self.executable.parent.mkdir(parents=True);self.executable.write_bytes(b'fixture main')
        self.info=Path(self.profile['app_private'])/'Contents/Info.plist'
        self.info.write_bytes(profiles.plistlib.dumps({'CFBundleIdentifier':'com.valvesoftware.steam','CFBundleName':'Steam',
            'CFBundleExecutable':'steam_osx','LSMultipleInstancesProhibited':True,
            'CFBundleURLTypes':[{'CFBundleURLName':'com.valvesoftware.steam','CFBundleURLSchemes':['steam']}]}))
        self.helper=Path(self.profile['app_private'])/'Contents/MacOS/Frameworks/Steam Helper.app/Contents/Info.plist'
        self.helper.parent.mkdir(parents=True)
        self.helper.write_bytes(b'<?xml version="1.0"?>\n<plist><dict>\n\t<key>CFBundleIdentifier</key>\n\t<string>msi.steamhelper.0123456789abcd</string>\n</dict></plist>\n')

    def tearDown(self):
        shutil.rmtree(self.profile['tmp'])
        for item in reversed(self.patches):item.stop()
        self.temp.cleanup()

    def ready(self):
        self.profile.update(stage='prepared',steam_launch_enabled=True,preparation_mode='vendor-code-v1',
                            library_sha256=app.digest(self.library),prepared_steam_sha256=app.digest(self.executable))
        profiles.save_profile(self.profile)

    def test_unprepared_and_changed_copies_cannot_launch(self):
        with patch.object(app.subprocess,'Popen') as launch,patch.object(app,'checked') as helper:
            with self.assertRaisesRegex(ValueError,'Prepare'):app.launch_steam('test')
            self.ready();self.executable.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'changed'):app.launch_steam('test')
            launch.assert_not_called();helper.assert_not_called()

    def test_launch_uses_only_private_helper_and_paths(self):
        self.ready()
        with patch.object(app,'owned_processes',return_value=[]),patch.object(app,'private_helper_loaded',return_value=False),patch.object(app,'bootstrap_helper') as helper,patch.object(app.subprocess,'Popen',return_value=MagicMock(pid=12345)) as launch:
            result=app.launch_steam('test')
            first=profiles.load_profile('test')['ipc_namespace']
            startup_guard.write(self.profile,{})
            app.launch_steam('test')
        self.assertEqual(result['pid'],12345)
        self.assertEqual(helper.call_count,2)
        args,kwargs=launch.call_args_list[0]
        self.assertIn(str(self.executable),args[0])
        self.assertEqual(kwargs['env']['HOME'],self.profile['home'])
        self.assertEqual(kwargs['env']['MSI_NAMESPACE'],self.profile['id'])
        # Every launch gets its own POSIX IPC names, shared by the helper.
        self.assertEqual(kwargs['env']['MSI_IPC_NAMESPACE'],first)
        self.assertNotEqual(first,self.profile['id'])
        second=profiles.load_profile('test')['ipc_namespace']
        self.assertNotEqual(first,second)
        plist=profiles.plistlib.loads((Path(self.profile['root'])/'private-helper.plist').read_bytes())
        self.assertEqual(plist['EnvironmentVariables']['MSI_IPC_NAMESPACE'],second)
        self.assertIn('ms2_'+second[:10],plist['ProgramArguments'][2])
        self.assertNotIn('SteamAppId',kwargs['env'])
        self.assertIn('-no-cef-sandbox',args[0])
        self.assertEqual(launch.call_count,4)
        self.assertIn('startup_guard.py',launch.call_args_list[1].args[0][1])
        self.assertEqual(startup_guard.read(self.profile)['state'],'checking')

    def test_leftover_helpers_are_stopped_and_running_games_refused(self):
        self.ready()
        helper={'pid':999999,'path':self.profile['app_private']+'/Contents/MacOS/ipcserver','game':False}
        state={'stopped':False}
        def stop(name,force=False,expected_startup_token=None):
            state['stopped']=True;return {'stopped_pids':[helper['pid']]}
        with patch.object(app,'owned_processes',side_effect=lambda *a,**k:[] if state['stopped'] else [helper]),\
             patch.object(app,'_stop_profile',side_effect=stop),patch.object(app,'private_helper_loaded',return_value=False),\
             patch.object(app,'bootstrap_helper'),patch.object(app.subprocess,'Popen',return_value=MagicMock(pid=1)):
            app.launch_steam('test')
        self.assertTrue(state['stopped'])
        game={'pid':999998,'path':self.profile['root']+'/Home/game/mvmmoclient','game':True}
        with patch.object(app,'owned_processes',return_value=[game]),patch.object(app.subprocess,'Popen') as launch:
            with self.assertRaisesRegex(ValueError,'still running'):app.launch_steam('test')
            launch.assert_not_called()

    def test_game_manifest_copies_the_install_without_the_account(self):
        source=self.base/'primary/steamapps';source.mkdir(parents=True)
        (source/'appmanifest_420790.acf').write_text('"AppState"\n{\n\t"appid"\t\t"420790"\n\t"Universe"\t\t"1"\n'
            '\t"LastPlayed"\t\t"1792779068"\n\t"buildid"\t\t"4406037"\n\t"LastOwner"\t\t"76561190000000000"\n}\n')
        self.profile['steam_source']=str(self.base/'primary')
        target=Path(self.profile['steam_private'])/'steamapps/appmanifest_420790.acf';target.parent.mkdir(parents=True)
        target.write_text('"AppState"\n{\n "appid" "420790"\n "StateFlags" "4"\n}\n')
        self.assertTrue(app.write_game_manifest(self.profile))
        text=target.read_text()
        self.assertIn('"Universe"',text);self.assertIn('"buildid"\t\t"4406037"',text)
        self.assertNotIn('LastOwner',text);self.assertNotIn('LastPlayed',text)
        self.assertFalse(app.write_game_manifest(self.profile))

    def test_profiles_run_the_current_sbpe_build(self):
        mac=self.base/'SBPE-Mac';mac.mkdir();(mac/'sbpe-mac.dylib').write_bytes(b'new build')
        root=private=Path(self.profile['root'])/'SBPE';private.mkdir();(private/'sbpe-mac.dylib').write_bytes(b'old build')
        self.profile['game']={'sbpe_root':str(root),'sbpe_sha256':app.digest(private/'sbpe-mac.dylib')};profiles.save_profile(self.profile)
        with patch.object(app,'MAC_SBPE',mac):
            self.assertTrue(app.refresh_sbpe(self.profile))
            self.assertEqual((private/'sbpe-mac.dylib').read_bytes(),b'new build')
            self.assertEqual(profiles.load_profile('test')['game']['sbpe_sha256'],app.digest(mac/'sbpe-mac.dylib'))
            self.assertFalse(app.refresh_sbpe(self.profile))

    def test_paused_testing_cannot_start_a_client(self):
        import json
        self.ready()
        (self.base/'client-testing-paused.json').write_text(json.dumps({'reason':'Paused fixture'}))
        with patch.object(app.subprocess,'Popen') as launch:
            with self.assertRaisesRegex(ValueError,'Paused fixture'):app.launch_steam('test')
            launch.assert_not_called()

    def test_startup_check_blocks_game_and_stop_cancels_monitor(self):
        self.ready();startup_guard.begin(self.profile,{})
        process={'pid':123,'path':str(self.executable),'game':False}
        with patch.object(app,'owned_processes',return_value=[process]),patch.object(app.subprocess,'Popen') as launch:
            with self.assertRaisesRegex(ValueError,'startup check'):app.launch_game('test')
            launch.assert_not_called()
        with patch.object(app,'owned_processes',return_value=[]),patch.object(app,'private_helper_loaded',return_value=False):
            app.stop_profile('test')
        self.assertEqual(startup_guard.read(self.profile)['state'],'cancelled')

    def test_startup_failure_detection_and_generation(self):
        self.assertIsNone(startup_guard.failure('ordinary startup'))
        self.assertIsNotNone(startup_guard.failure('sandbox initialization failed: Operation not permitted'))
        self.assertIsNotNone(startup_guard.failure('GPU process exited unexpectedly\n'*3))
        self.assertIsNotNone(startup_guard.failure('CSteamEngine::BMainLoop appears to have stalled > 15 seconds'))
        first=startup_guard.begin(self.profile,{})
        second=startup_guard.begin(self.profile,{})
        with patch.object(app,'stop_profile') as stop:
            startup_guard.fail(app,self.profile,first['token'],'Old launch failure')
            stop.assert_not_called()
        self.assertEqual(startup_guard.read(self.profile)['token'],second['token'])
        with patch.object(app,'owned_processes',return_value=[{'game':True}]),patch.object(app,'stop_profile') as stop:
            startup_guard.fail(app,self.profile,second['token'],'Test failure')
            stop.assert_not_called()
        self.assertEqual(startup_guard.read(self.profile)['state'],'failed')

    def test_startup_needs_a_loaded_login_or_desktop_window(self):
        hidden='UB-65536: AfterCreated handle:65536 type:12: (0, 0) 0x0\nSP Shared JS Context: STARTUP LoadEnd t=1.0\n'
        created='SP DesktopLoginWindow_uid0: AfterCreated handle:131073 type:4: (0, 0) 700x440\n'
        loaded='SP DesktopLoginWindow_uid0: STARTUP LoadEnd t=1.106\n'
        self.assertFalse(startup_guard.desktop_ready('Verification complete\n'+hidden))
        self.assertFalse(startup_guard.desktop_ready(created+hidden))
        self.assertTrue(startup_guard.desktop_ready(created+loaded))
        desktop='SP Desktop_uid0: AfterCreated handle:196610 type:4: (0, 0) 1280x800\nSP Desktop_uid0-\'Steam\': STARTUP LoadEnd t=3.2\n'
        self.assertTrue(startup_guard.desktop_ready(desktop))

    def test_startup_failure_stops_only_the_affected_profile(self):
        state=startup_guard.begin(self.profile,{})
        with patch.object(app,'owned_processes',return_value=[]),patch.object(app,'stop_profile') as stop,patch.object(startup_guard.time,'sleep'):
            startup_guard.fail(app,self.profile,state['token'],'Repeated web UI failure')
        self.assertEqual(stop.call_args_list[0].args,('test',))
        self.assertEqual(stop.call_args_list[1].kwargs,{'force':True,'expected_startup_token':state['token']})
        self.assertEqual(startup_guard.read(self.profile)['state'],'failed')

    def test_old_monitor_cannot_stop_a_new_launch(self):
        old=startup_guard.begin(self.profile,{})
        startup_guard.begin(self.profile,{})
        with patch.object(app,'owned_processes',return_value=[{'pid':123,'path':str(self.executable),'game':False}]),patch.object(app.os,'kill') as kill,patch.object(app,'private_helper_loaded') as helper:
            app.stop_profile('test',expected_startup_token=old['token'])
            kill.assert_not_called();helper.assert_not_called()

    def test_no_game_launch_before_private_steam_is_running(self):
        self.ready()
        with patch.object(app,'owned_processes',return_value=[]),patch.object(app.subprocess,'Popen') as launch:
            with self.assertRaisesRegex(ValueError,'sign in first'):app.launch_game('test')
            launch.assert_not_called()

    def test_stop_excludes_primary_process_and_rechecks_pid(self):
        private=[(123,str(self.executable)),(124,str(self.executable))]
        primary=(999,'/Applications/Steam.app/Contents/MacOS/steam_osx')
        reused=[(123,primary[1]),private[1],primary]
        # PID 123 gets reused by the primary app before the identity recheck.
        with patch.object(app,'process_paths',side_effect=[private+[primary],private+[primary],reused,reused]),patch.object(app.os,'kill') as kill,\
             patch.object(app,'private_helper_loaded',return_value=False),patch.object(app,'request_steam_exit') as quit,\
             patch.object(app,'wait_for_exit',return_value=[]):
            app.stop_profile('test')
        quit.assert_called_once()
        kill.assert_called_once_with(124,app.signal.SIGTERM)

    def test_stop_escalates_when_steam_ignores_sigterm(self):
        steam={'pid':124,'path':str(self.executable),'game':False}
        with patch.object(app,'owned_processes',return_value=[steam]),patch.object(app.os,'kill') as kill,\
             patch.object(app,'private_helper_loaded',return_value=False),patch.object(app,'request_steam_exit') as quit,\
             patch.object(app,'wait_for_exit',side_effect=[[steam],[steam],[]]):
            self.assertEqual(app.stop_profile('test')['stopped_pids'],[124])
        quit.assert_called_once()
        self.assertEqual([c.args for c in kill.call_args_list],[(124,app.signal.SIGTERM),(124,app.signal.SIGKILL)])

    def test_private_copy_gets_its_own_app_identity(self):
        self.assertTrue(app.apply_private_identity(self.profile))
        info=profiles.plistlib.loads(self.info.read_bytes())
        self.assertEqual(info['CFBundleIdentifier'],'com.macsteam.isolation.'+self.profile['id']+'.steam')
        self.assertEqual(info['CFBundleName'],'Steam (test)')
        for key in ('CFBundleURLTypes','LSMultipleInstancesProhibited'):self.assertNotIn(key,info)
        self.assertEqual(info['CFBundleExecutable'],'steam_osx')
        # A helper renamed by the earlier test build gets Valve's signed ID back.
        self.assertIn(b'<string>com.valvesoftware.steam.helper</string>',self.helper.read_bytes())
        self.assertFalse(app.apply_private_identity(self.profile))

    def test_edited_path_and_helper_are_rejected(self):
        for key,value in [('app_private','/Applications/Steam.app'),('mach_service',profiles.SERVICE)]:
            original=self.profile[key];self.profile[key]=value;profiles.save_profile(self.profile)
            with self.assertRaises(ValueError):profiles.load_profile('test')
            self.profile[key]=original;profiles.save_profile(self.profile)

    def test_inspection_never_starts_steam(self):
        with patch.object(app,'process_paths',return_value=[]),patch.object(app.subprocess,'Popen') as launch:
            result=app.list_profiles()
        self.assertEqual(len(result['profiles']),1)
        self.assertIsNone(result['profile_limit'])
        launch.assert_not_called()


if __name__=='__main__':unittest.main(verbosity=2)
