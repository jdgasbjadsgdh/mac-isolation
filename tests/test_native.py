"""Native fixtures only: never launches Steam or changes its launch agent."""
import concurrent.futures
import errno
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from profiles import new_profile, environment, guarded_command, helper_plist, write_plist, SERVICE
import profiles as profile_module
import app_backend


class IsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='msi-native-tests-')
        cls.base = Path(cls.temp.name)
        cls.primary = cls.base/'primary Steam';cls.primary.mkdir()
        cls.marker = cls.primary/'marker';cls.marker.write_text('PRIMARY')
        cls.a = new_profile('A', cls.base/'profiles', cls.primary)
        cls.b = new_profile('B', cls.base/'profiles', cls.primary)
        cls.c = new_profile('C', cls.base/'profiles', cls.primary)
        cls.profiles = (cls.a, cls.b, cls.c)
        cls.values = tuple(zip(cls.profiles, ('A', 'B', 'C')))
        # launchd's test executable must be outside Downloads. Otherwise dyld
        # can block reopening an unbundled test image before main() starts.
        cls.binaries=cls.base/'Binaries';cls.binaries.mkdir(mode=0o700)
        for name in ('native_fixture','native_fixture_x86_64','fixture_library.dylib','msi-ps'):
            if (ROOT/'build'/name).exists():shutil.copy2(ROOT/'build'/name,cls.binaries/name)
        cls.original_library=profile_module.LIBRARY
        cls.library=cls.binaries/'libmacsteam_isolation.dylib'
        shutil.copy2(cls.original_library,cls.library)
        profile_module.LIBRARY=cls.library
        for profile in cls.profiles:
            shutil.copy2(ROOT/'build/fixture_library.dylib',Path(profile['steam_private'])/'fixture_library.dylib')
        cls.fixture = cls.binaries/'native_fixture'

    @classmethod
    def tearDownClass(cls):
        for profile in cls.profiles:
            for mode in ('ipc-clean', 'preferences-clean'):
                subprocess.run(guarded_command(profile, [cls.fixture, mode]), env=environment(profile), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            # Delete only this fixture's namespaced preference files.
            for file in (Path.home()/'Library/Preferences').glob('com.macsteam.isolation.'+profile['id']+'.prefs.*.plist'):
                file.unlink()
            shutil.rmtree(profile['tmp'])
        profile_module.LIBRARY=cls.original_library
        cls.temp.cleanup()

    def run_fixture(self, profile, *arguments, inject=True, executable=None, check=True):
        command = guarded_command(profile, [executable or self.fixture]+list(arguments), inject)
        result = subprocess.run(command, env=environment(profile), text=True, capture_output=True, timeout=15)
        if check:
            self.assertEqual(result.returncode, 0, result.stderr+'\n'+result.stdout)
        return result

    def test_identity_and_child_environment(self):
        for profile in self.profiles:
            for mode in ('identity', 'spawn', 'spawn-scrubbed', 'spawnp', 'execv', 'execvp'):
                data = json.loads(self.run_fixture(profile, mode).stdout)
                self.assertEqual(data['home'], profile['home'])
                self.assertEqual(data['pw_home'], profile['home'])
                self.assertEqual(data['pw_r_home'], profile['home'])
                self.assertEqual(data['foundation_home'], profile['home'])
                self.assertEqual(data['foundation_tmp'], profile['tmp']+'/')
                self.assertEqual(data['uid'], os.getuid())
                self.assertTrue(data['alive'])
                self.assertTrue(data['languages'])

    def test_shell_helpers_keep_the_profile(self):
        modes=('shell-spawn','shell-spawnp','shell-exec','shell-system','shell-popen',
               'shell-dash','shell-combined','shell-scrubbed-spawn','shell-scrubbed-system','shell-scrubbed-popen')
        for profile in self.profiles:
            for mode in modes:
                with self.subTest(profile=profile['name'],mode=mode):
                    data=json.loads(self.run_fixture(profile,mode).stdout)
                    self.assertEqual(data['home'],profile['home'])
                    self.assertEqual(data['pw_home'],profile['home'])
                    self.assertEqual(data['foundation_home'],profile['home'])
                    self.assertEqual(data['namespace'],profile['id'])
                    self.assertEqual(data['insertion'],str(self.library))
                    self.assertTrue(data['languages'])
        intel=self.binaries/'native_fixture_x86_64'
        if intel.exists():
            for mode in ('shell-spawn','shell-popen','shell-system'):
                data=json.loads(self.run_fixture(self.a,mode,executable=intel).stdout)
                self.assertEqual(data['pw_home'],self.a['home'])

    def test_shell_quoting_arguments_status_and_library_selection(self):
        import shlex
        command=shlex.quote(str(self.fixture))+' identity; exit 37'
        for shell in ('/bin/sh','/bin/bash','/bin/zsh'):
            result=self.run_fixture(self.a,'shell-command',shell,command,check=False)
            self.assertEqual(result.returncode,37,result.stderr)
            self.assertEqual(json.loads(result.stdout)['pw_home'],self.a['home'])
            result=self.run_fixture(self.a,'shell-command',shell,'printf \'%s\\n\' "$0" "$1"')
            self.assertEqual(result.stdout.splitlines(),['fixture $zero;',"argument ' $one;"])
        # Use literal shell metacharacters in a captured value: none may execute.
        marker=self.base/'must-not-exist'
        value="a'; touch "+shlex.quote(str(marker))+"; # $HOME `false`\nend"
        env=environment(self.a);env['MSI_TRACE']=value
        command=guarded_command(self.a,[self.fixture,'shell-command','/bin/sh','printf \'%s\' "$MSI_TRACE"'])
        result=subprocess.run(command,env=env,text=True,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(result.stdout,value)
        self.assertFalse(marker.exists())
        # An Intel game may have another injected library. Helpers retain only
        # the universal isolation core when crossing the protected shell.
        libraries=str(self.library)+':'+str(self.binaries/'fixture_library.dylib')
        command=guarded_command(self.a,[self.fixture,'shell-popen'],libraries=libraries)
        env=environment(self.a);env['DYLD_INSERT_LIBRARIES']=libraries
        result=subprocess.run(command,env=env,text=True,capture_output=True,timeout=15)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(json.loads(result.stdout)['insertion'],str(self.library))

    def test_kernel_blocks_foreign_ipc_even_without_the_shim(self):
        def mapped(profile,name):
            value=14695981039346656037
            for byte in name.encode():value=((value^byte)*1099511628211)&((1<<64)-1)
            return '/ms2_'+profile['id'][:10]+'_'+format(value&0xffffffffffff,'012x')
        foreign=(mapped(self.b,'/msi_fixture_fixed_shm'),mapped(self.b,'/msi_fixture_fixed_sem'))
        primary=('/msitest_'+self.a['id'][:12]+'m','/msitest_'+self.a['id'][:12]+'s')
        fixture=str(self.fixture)
        subprocess.run([fixture,'ipc-raw',*foreign,'create'],capture_output=True,check=True,timeout=10)
        subprocess.run([fixture,'ipc-raw',*primary,'create'],capture_output=True,check=True,timeout=10)
        try:
            for names in (foreign,primary):
                for operation in ('open','unlink'):
                    data=json.loads(self.run_fixture(self.a,'ipc-raw',*names,operation,inject=False).stdout)
                    self.assertIn(data['shm_error'],(errno.EPERM,errno.EACCES))
                    self.assertIn(data['sem_error'],(errno.EPERM,errno.EACCES))
                # Denied unlink must leave the disposable outside objects intact.
                result=subprocess.run([fixture,'ipc-raw',*names,'open'],capture_output=True,text=True,check=True,timeout=10)
                self.assertEqual(json.loads(result.stdout),{'shm_error':0,'sem_error':0})
            own=(mapped(self.a,'/msi_fixture_fixed_shm'),mapped(self.a,'/msi_fixture_fixed_sem'))
            data=json.loads(self.run_fixture(self.a,'ipc-raw',*own,'create',inject=False).stdout)
            self.assertEqual(data,{'shm_error':0,'sem_error':0})
            self.run_fixture(self.a,'ipc-raw',*own,'unlink',inject=False)
        finally:
            for names in (foreign,primary):subprocess.run([fixture,'ipc-raw',*names,'unlink'],capture_output=True,timeout=10)

    def test_kernel_protects_global_steam_pipes_without_the_shim(self):
        path=Path('/private/tmp')/('steam-msi-kernel-'+self.a['id'][:12])
        path.write_text('PRIMARY FIXTURE')
        try:
            denied=self.run_fixture(self.a,'files',str(path),'BAD',inject=False,check=False)
            self.assertEqual(denied.returncode,10)
            self.assertEqual(path.read_text(),'PRIMARY FIXTURE')
            data=json.loads(self.run_fixture(self.a,'files',str(path),'PRIVATE').stdout)
            self.assertEqual(data['value'],'PRIVATE')
            self.assertEqual(path.read_text(),'PRIMARY FIXTURE')
        finally:path.unlink()

    def test_files_and_kernel_guard(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            values = list(pool.map(lambda pair: json.loads(self.run_fixture(pair[0], 'files', str(self.marker), pair[1]).stdout), self.values))
        self.assertEqual([v['value'] for v in values], ['A','B','C'])
        self.assertEqual(self.marker.read_text(), 'PRIMARY')
        self.assertEqual((Path(self.a['steam_private'])/'marker').read_text(),'A')
        self.assertEqual((Path(self.b['steam_private'])/'marker').read_text(),'B')
        self.assertEqual((Path(self.c['steam_private'])/'marker').read_text(),'C')
        # Disable the shim: kernel policy must still stop host-file writes.
        denied = self.run_fixture(self.a, 'files', str(self.marker), 'BAD', inject=False, check=False)
        self.assertEqual(denied.returncode,10)
        self.assertEqual(self.marker.read_text(),'PRIMARY')

    def test_posix_ipc_names(self):
        for profile, value in self.values:
            self.assertEqual(json.loads(self.run_fixture(profile,'ipc-create',value).stdout)['mode'],0o600)
        for profile, value in self.values:
            self.assertEqual(json.loads(self.run_fixture(profile,'ipc-read').stdout)['value'],value)

    def test_ps_query_works_inside_the_sandbox(self):
        # Steam accepts its web UI socket only after this exact query succeeds.
        query='/bin/ps -x -o pid=,ppid='
        blocked=self.run_fixture(self.a,'popen-command',query,inject=False,check=False)
        self.assertNotEqual(blocked.returncode,0)
        self.assertIn('Operation not permitted',blocked.stderr)
        for profile in self.profiles:
            result=self.run_fixture(profile,'popen-command',query)
            rows=[tuple(map(int,line.split())) for line in result.stdout.splitlines()]
            self.assertTrue(rows and all(len(row)==2 for row in rows))
            self.assertIn(os.getpid(),{row[0] for row in rows})
            result=self.run_fixture(profile,'spawn-argv','/bin/ps','-o','pid=,ppid=','-p',str(os.getpid()))
            self.assertEqual(result.stdout.split(),[str(os.getpid()),str(os.getppid())])

    def test_each_launch_name_space_is_separate_and_released(self):
        import uuid
        session=dict(self.a,ipc_namespace=uuid.uuid4().hex)
        self.assertEqual(json.loads(self.run_fixture(session,'ipc-create','SESSION').stdout)['mode'],0o600)
        record=Path(session['tmp'])/('ipc-'+session['ipc_namespace'][:10]+'.names')
        kinds=sorted(line.split()[0] for line in record.read_text().splitlines())
        self.assertEqual(kinds,['m','s'])
        # The profile's previous name space never sees this session's objects.
        self.assertEqual(self.run_fixture(dict(self.a,ipc_namespace=uuid.uuid4().hex),'ipc-read',check=False).returncode,24)
        self.assertEqual(json.loads(self.run_fixture(session,'ipc-read').stdout)['value'],'SESSION')
        self.assertEqual(app_backend.release_ipc_names(session),2)
        self.assertFalse(record.exists())
        self.assertEqual(self.run_fixture(session,'ipc-read',check=False).returncode,24)

    def test_private_clients_cannot_see_or_follow_the_normal_steam(self):
        normal=[pid for pid,path in app_backend.process_paths() if Path(path).name=='steam_osx' and 'MacSteam Isolation' not in path]
        if not normal:self.skipTest('The normal Steam is not running.')
        outside=json.loads(subprocess.run([str(self.fixture),'apps',str(normal[0])],capture_output=True,text=True,check=True,timeout=15).stdout)
        self.assertEqual(outside['bundle'],'com.valvesoftware.steam')
        self.assertIn(normal[0],outside['same'])
        inside=json.loads(self.run_fixture(self.a,'apps',str(normal[0])).stdout)
        self.assertEqual(inside['bundle'],'com.macsteam.isolation.foreign.com.valvesoftware.steam')
        self.assertNotIn(normal[0],inside['same'])

    def test_steam_notifications_stay_inside_each_profile(self):
        # Steam's main app and web helper signal each other with session-wide
        # distributed notifications; two clients obeyed each other's.
        name='com.valvesoftware.steam.MSIFixture'
        def listen(profile):
            if profile is None:
                child=subprocess.Popen([str(self.fixture),'dnc-listen',name,'3'],stdout=subprocess.PIPE,text=True)
            else:
                child=subprocess.Popen(guarded_command(profile,[self.fixture,'dnc-listen',name,'3']),env=environment(profile),stdout=subprocess.PIPE,text=True)
            self.assertEqual(child.stdout.readline().strip(),'READY');return child
        listeners={'normal':listen(None),'A':listen(self.a),'B':listen(self.b)}
        self.run_fixture(self.a,'dnc-post',name)
        counts={key:json.loads(child.communicate(timeout=15)[0])['count'] for key,child in listeners.items()}
        self.assertEqual(counts,{'normal':0,'A':1,'B':0})
        listeners={'normal':listen(None),'A':listen(self.a)}
        subprocess.run([str(self.fixture),'dnc-post',name],check=True,timeout=10)
        counts={key:json.loads(child.communicate(timeout=15)[0])['count'] for key,child in listeners.items()}
        self.assertEqual(counts,{'normal':1,'A':0})

    def test_steam_client_ports_are_private_per_profile(self):
        # Games reach their Steam client on fixed loopback ports. Never touch
        # the real ports: the user's own Steam listens on them.
        server=subprocess.Popen(guarded_command(self.a,[self.fixture,'tcp-serve','57343','PROFILE-A']),env=environment(self.a),stdout=subprocess.PIPE,text=True)
        try:
            self.assertEqual(server.stdout.readline().split(),['READY','57343'])
            self.assertEqual(json.loads(self.run_fixture(self.a,'tcp-get','57343').stdout),{'error':0,'token':'PROFILE-A'})
        finally:
            server.wait(timeout=10)
        self.assertEqual(json.loads(self.run_fixture(self.b,'tcp-get','57343').stdout)['error'],errno.ECONNREFUSED)
        # Without the shim the kernel profile refuses the real port.
        self.assertIn(json.loads(self.run_fixture(self.a,'tcp-get','57343',inject=False).stdout)['error'],(errno.EPERM,errno.EACCES))

    def test_fifo_creation_matches_open_redirection(self):
        for profile in self.profiles:
            for path in (str(self.primary/'steam.pipe'),'/tmp/steam-msi-fixture.pipe'):
                self.assertTrue(json.loads(self.run_fixture(profile,'fifo',path).stdout)['fifo'])

    def test_dynamic_loading_uses_private_client_path(self):
        for profile in self.profiles:
            result=json.loads(self.run_fixture(profile,'library',str(self.primary/'fixture_library.dylib')).stdout)
            self.assertEqual(result['value'],42)
            self.assertEqual(Path(result['loaded_path']).resolve(),Path(profile['steam_private'])/'fixture_library.dylib')

    def test_signals_only_reach_same_sandbox(self):
        for profile in self.profiles:
            self.assertTrue(json.loads(self.run_fixture(profile,'signal-tree').stdout)['child_signal'])
        # SIGCONT is harmless even if the policy regresses; use a disposable
        # unguarded fixture, never a real application, as the outside target.
        process=subprocess.Popen([str(self.fixture),'wait'],stdout=subprocess.PIPE,text=True)
        try:
            self.assertEqual(process.stdout.readline().strip(),'READY')
            self.assertTrue(json.loads(self.run_fixture(self.a,'signal-outside',str(process.pid)).stdout)['denied'])
        finally:
            process.terminate();process.wait(timeout=5);process.stdout.close()

    def test_unix_sockets(self):
        servers=[]
        try:
            for profile,value in self.values:
                process=subprocess.Popen(guarded_command(profile,[self.fixture,'unix-server',value]),env=environment(profile),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
                servers.append(process)
                self.assertEqual(process.stdout.readline().strip(),'READY',process.stderr.read() if process.poll() is not None else '')
            for profile,value in self.values:
                self.assertEqual(json.loads(self.run_fixture(profile,'unix-client').stdout)['value'],value)
            for process in servers:self.assertEqual(process.wait(timeout=5),0)
        finally:
            for process in servers:
                if process.poll() is None:process.terminate();process.wait(timeout=5)
                process.stdout.close();process.stderr.close()

    def test_preferences(self):
        for profile,value in self.values:
            self.assertEqual(json.loads(self.run_fixture(profile,'preferences',value).stdout)['value'],value)
        for profile,value in self.values:
            self.assertEqual(json.loads(self.run_fixture(profile,'preferences').stdout)['value'],value)
        ordinary=subprocess.run([str(self.fixture),'preferences'],capture_output=True,text=True,check=True,timeout=10)
        self.assertIsNone(json.loads(ordinary.stdout)['value'])

    def test_mach_services(self):
        registered=[]
        try:
            for profile,marker in zip(self.profiles, ('101','202','303')):
                path=Path(profile['root'])/'fixture-agent.plist'
                write_plist(path,helper_plist(profile,self.fixture,['mach-server'],{'MSI_FIXTURE_MARKER':marker}))
                domain='gui/{}'.format(os.getuid())
                command=['/bin/launchctl','bootstrap',domain,str(path)]
                result=subprocess.run(command,capture_output=True,text=True,timeout=15)
                self.assertEqual(result.returncode,0,result.stderr)
                registered.append(domain+'/'+profile['mach_service'])
            for profile,expected in zip(self.profiles, (101,202,303)):
                result=self.run_fixture(profile,'mach-client',check=False)
                if result.returncode:
                    diagnostic=subprocess.run(['/bin/launchctl','print','gui/{}/{}'.format(os.getuid(),profile['mach_service'])],capture_output=True,text=True,timeout=10)
                    state='\n'.join(line for line in diagnostic.stdout.splitlines() if any(s in line for s in ('state =','pid =','exit code','runs =')))
                    stderr=Path(profile['root'])/'helper.stderr.log'
                    import re
                    pid=re.search(r'\bpid = (\d+)',diagnostic.stdout)
                    if pid:
                        evidence=ROOT/'evidence';evidence.mkdir(exist_ok=True)
                        subprocess.run(['/usr/bin/sample',pid.group(1),'1','1','-file',str(evidence/'mach-startup-sample.txt')],capture_output=True,timeout=10)
                    self.fail(profile['name']+' Mach client '+str(result.returncode)+'\n'+state+'\n'+result.stderr+'\n'+(stderr.read_text(errors='replace') if stderr.exists() else ''))
                self.assertEqual(json.loads(result.stdout)['marker'],expected)
            # Even without the shim, a guarded process cannot discover the
            # existing real Steam helper. Only our private aliases can work.
            denied=self.run_fixture(self.a,'mach-client',inject=False,check=False)
            self.assertEqual(denied.returncode,43)
        finally:
            for service in registered:
                self.assertTrue(service.split('/')[-1].startswith('com.macsteam.isolation.'))
                subprocess.run(['/bin/launchctl','bootout',service],capture_output=True,text=True,timeout=10)

    def test_rosetta_identity(self):
        path=self.binaries/'native_fixture_x86_64'
        if not path.exists():self.skipTest('Intel fixture not built')
        data=json.loads(self.run_fixture(self.a,'identity',executable=path).stdout)
        self.assertEqual(data['pw_home'],self.a['home'])


if __name__=='__main__':unittest.main(verbosity=2)
