# MacSteam Isolation

An experimental macOS application for managing multiple private Steam profiles
and launching StarBreak with Mac SBPE. The native Swift interface creates as
many profiles as you need; there is no fixed two-client limit. Each profile
has its own Steam files, settings, keychain and IPC names.

**Current status: compatibility preview 0.1.2.** The latest local user report
still has private Steam stuck at **“Verifying installation.”** A disposable
profile previously reached the Steam sign-in window, but reliable sign-in,
Steam updates and simultaneous StarBreak gameplay are not verified. This
upload shares the existing application and source. It does not contain a new
fix for that startup problem. Isolation-engine work remains paused.

## Download

[Download the Mac app ZIP](downloads/MacSteam-Isolation-0.1.2-preview-2026-10-25.zip?raw=true).
Checksums are in [downloads/SHA256SUMS.txt](downloads/SHA256SUMS.txt).
The app contains universal Intel/Apple silicon executables, Python backend
source, a native isolation library and helper tools. Steam, StarBreak, account
credentials and personal profiles are not included.

## Requirements

- macOS 13 or newer.
- Steam installed normally, with StarBreak already downloaded on the Mac.
- `/usr/bin/python3`, supplied by Apple Command Line Tools on the development
  machine. The current app expects that exact path.
- A compatible Mac SBPE folder at **`~/Downloads/SBPE-Mac-Windows-Parity`**.
  The current backend uses this location and supports the Intel StarBreak
  executable with SHA-256
  `8ab9adf4a5900a18532f3403bd07f9515fb59f4afbc5e8ebdb795aeeaf698d57`.
- Rosetta on Apple silicon for the Intel game/Steam components that need it.
- Enough storage and memory for additional private Steam installations.

This is specific to Steam/StarBreak. It is not a general Sandboxie clone or
a security boundary for running untrusted applications. Private Steam uses
`-no-cef-sandbox` because CEF cannot nest its sandbox inside this kernel profile.
The app's outer restrictions remain, but Chromium's separate renderer sandbox
is disabled for those private clients.

## First-time tutorial

1. Extract the app ZIP and put **MacSteam Isolation.app** in a permanent
   location, such as Applications. Open it. If macOS asks about an unverified
   developer, use Finder's **Open** action for the downloaded app; this preview
   is ad-hoc signed, not notarized.
2. Click **Add profile** (or **Create first profile**) and choose a distinct
   name for that Steam account.
3. Select the new profile and click **Prepare**. This creates its private
   files and copies the supported StarBreak/SBPE installation. Each profile
   gets its own copy of the current SBPE settings on preparation.
4. Click **Start Steam** for that profile. Allow the startup check to finish.
   The current guard can take up to about a minute; success requires an actual
   sign-in or desktop window, not merely a running helper process.
5. When the private Steam window is ready, sign in to the account intended
   for that profile. Authentication is done in Steam, not in this manager.
6. After startup passes, click **Launch with SBPE**. Verify the character/account
   inside StarBreak before using additional profiles: account routing remains
   a live-test requirement.
7. Add another profile and repeat. A profile is an independent Steam instance;
   this app does not duplicate a signed-in account automatically.

Use **Stop profile** to stop that profile's processes. Closing the manager
window leaves launched clients running. Avoid deleting profile folders while
their Steam or game is running. Preparing again updates that profile's private
files; keep a backup of settings you have customized.

## Verifying installation, UI flashing and keychain prompts

If Steam remains on **Verifying installation**, the profile has not finished
startup. Do not treat that screen as successful isolation or keep opening more
copies. Read the profile's startup/status message and logs; the startup guard
is intended to stop repeated failures only for the affected profile and to
avoid stopping an already running game.

Earlier builds produced repeated window activation/UI flashing. Version 0.1.2
namespaces Steam's distributed notifications and adds a non-setuid `msi-ps`
helper. Those changes addressed a reproduced activation loop, but the broader
compatibility preview still needs real account testing.

The app prepares a private keychain for each profile. If a **Keychain Not Found**
dialog unexpectedly offers **Reset To Defaults**, cancel it and inspect the
profile failure instead of resetting the Mac's normal keychain. The isolation
code is intended to leave the primary keychain defaults/search list unchanged.

## Where files live

Profiles are stored under:

```text
~/Library/Application Support/MacSteam Isolation/profiles/<profile-name>/
```

They contain private application files, settings and logs. Treat that directory
as personal account data. It is deliberately absent from this repository and
from the downloadable app. Public bug reports should include only redacted
errors, never login data, tokens, keychain files or whole profile archives.

## Build from source

Install Apple Command Line Tools and use a Mac capable of building the Intel
and Apple silicon targets. Clone or download this repository, then run:

```bash
python3 build_app.py
```

The build writes **MacSteam Isolation.app** beside the source directory, builds
the native helpers for both architectures, packages the Swift UI and Python
backend, and ad-hoc signs/verifies the resulting app. It does not launch Steam
or a game.

Main components:

| Path | Purpose |
| --- | --- |
| `src/MacSteamIsolation.swift` | Native profile manager UI |
| `app_backend.py` | Preparation, launch and explicit stop actions |
| `profiles.py` | Profile files, environment and sandbox setup |
| `startup_guard.py` | Startup failure/stall monitoring |
| `src/isolation.m` | Native Steam path, IPC and notification isolation |
| `src/keychain_setup.m` | Private keychain preparation |
| `src/msi_ps.c` | Non-setuid process-query compatibility helper |
| `tests/` | Disposable native/backend/keychain/startup fixtures |

`isolate.py` also offers command-line diagnostics and explicit profile actions;
run `python3 isolate.py --help` for its commands. Tests can create disposable
processes and private keychains, so review them before running. Historical
development notes are in [HISTORY.txt](HISTORY.txt); where those notes conflict
with the current status above, the current status takes precedence.

The distributed app's code signature and source syntax were checked for this
upload. No Steam client or game was started or restarted during publication.
