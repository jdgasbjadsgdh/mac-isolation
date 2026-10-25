"""Build the native UI. This never launches Steam or a game."""
from pathlib import Path
import plistlib
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
APP = ROOT.parent/'MacSteam Isolation.app'
BUILD = ROOT/'build'
BUILD.mkdir(exist_ok=True)
keychain=BUILD/'keychain_setup'
if not keychain.exists() or keychain.stat().st_mtime<(ROOT/'src/keychain_setup.m').stat().st_mtime:
    subprocess.run(['xcrun','clang','-arch','arm64','-arch','x86_64','-mmacosx-version-min=11.0',
                    '-std=c11','-fobjc-arc','-O2','-Wall','-Wextra','-Werror','-Wno-deprecated-declarations',
                    '-framework','Foundation','-framework','Security','-o',str(BUILD/'keychain_setup.next'),
                    str(ROOT/'src/keychain_setup.m')],check=True)
    os.replace(str(BUILD/'keychain_setup.next'),str(keychain))
universal=['xcrun','clang','-arch','arm64','-arch','x86_64','-mmacosx-version-min=11.0','-O2','-Wall','-Wextra','-Werror']
def stale(output,*sources):
    return not output.exists() or any(output.stat().st_mtime<(ROOT/s).stat().st_mtime for s in sources)
library=BUILD/'libmacsteam_isolation.dylib'
if stale(library,'src/isolation.m'):
    subprocess.run(universal+['-dynamiclib','-fobjc-arc','-Wno-unused-parameter','-framework','Foundation','-framework','CoreFoundation',
                              '-o',str(BUILD/'libmacsteam_isolation.next.dylib'),str(ROOT/'src/isolation.m')],check=True)
    os.replace(str(BUILD/'libmacsteam_isolation.next.dylib'),str(library))
ps_tool=BUILD/'msi-ps'
if stale(ps_tool,'src/msi_ps.c'):
    subprocess.run(universal+['-std=c11','-o',str(BUILD/'msi-ps.next'),str(ROOT/'src/msi_ps.c')],check=True)
    os.replace(str(BUILD/'msi-ps.next'),str(ps_tool))
fixture=BUILD/'native_fixture'
if stale(fixture,'tests/native_fixture.m'):
    subprocess.run(universal+['-fobjc-arc','-Wno-unused-parameter','-Wno-unused-result','-Wno-deprecated-declarations','-framework','Foundation','-framework','CoreFoundation','-framework','AppKit',
                              '-o',str(BUILD/'native_fixture.next'),str(ROOT/'tests/native_fixture.m')],check=True)
    os.replace(str(BUILD/'native_fixture.next'),str(fixture))
for architecture in ('arm64', 'x86_64'):
    binary=BUILD/('ui-'+architecture)
    if binary.is_file() and binary.stat().st_mtime > (ROOT/'src/MacSteamIsolation.swift').stat().st_mtime:
        continue
    subprocess.run(['xcrun','swiftc','-parse-as-library','-O','-target',architecture+'-apple-macosx13.0',
                    str(ROOT/'src/MacSteamIsolation.swift'),'-o',str(BUILD/('ui-'+architecture))],check=True)
contents = APP/'Contents'
(contents/'MacOS').mkdir(parents=True,exist_ok=True)
resources=contents/'Resources';resources.mkdir(exist_ok=True)
iconset=BUILD/'AppIcon.iconset';iconset.mkdir(exist_ok=True)
icon_png=BUILD/'app-icon-1024.png'
if not icon_png.exists():
    subprocess.run(['xcrun','swift',str(ROOT/'src/DrawIcon.swift'),str(icon_png)],check=True)
for size in (16,32,128,256,512):
    for scale in (1,2):
        suffix='@2x' if scale==2 else ''
        subprocess.run(['/usr/bin/sips','-z',str(size*scale),str(size*scale),str(icon_png),'--out',str(iconset/('icon_{}x{}{}.png'.format(size,size,suffix)))],check=True,stdout=subprocess.DEVNULL)
subprocess.run(['/usr/bin/iconutil','-c','icns',str(iconset),'-o',str(resources/'AppIcon.icns')],check=True)
subprocess.run(['xcrun','lipo','-create',str(BUILD/'ui-arm64'),str(BUILD/'ui-x86_64'),'-output',str(BUILD/'ui-universal.next')],check=True)
os.replace(str(BUILD/'ui-universal.next'),str(contents/'MacOS/MacSteamIsolation'))
for name in ('app_backend.py','profiles.py','startup_guard.py'):
    shutil.copy2(str(ROOT/name),str(resources/(name+'.next')))
    os.replace(str(resources/(name+'.next')),str(resources/name))
shutil.copy2(str(keychain),str(resources/'keychain_setup.next'))
os.replace(str(resources/'keychain_setup.next'),str(resources/'keychain_setup'))
for name in ('libmacsteam_isolation.dylib','msi-ps'):
    shutil.copy2(str(BUILD/name),str(resources/(name+'.next')))
    os.replace(str(resources/(name+'.next')),str(resources/name))
(contents/'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier':'local.macsteam.isolation.manager', 'CFBundleName':'MacSteam Isolation',
    'CFBundleDisplayName':'MacSteam Isolation', 'CFBundleExecutable':'MacSteamIsolation',
    'CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.2','CFBundleVersion':'3',
    'CFBundleIconFile':'AppIcon',
    'LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,
    'NSPrincipalClass':'NSApplication','LSApplicationCategoryType':'public.app-category.utilities'
}))
subprocess.run(['/usr/bin/codesign','--force','--deep','--sign','-',str(APP)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(APP)],check=True)
print(APP)
