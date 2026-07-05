# Windows desktop app — design & delivery plan

Status: phases 1–2 (foundation, local install) shipped on
`desktop-app/13-windows`; phase 3 (parity polish) planned; phase 4
partially in place — the `build-windows` job and Azure
Trusted Signing wiring exist (`release.yml`,
`sign-windows-test.yml`), pending SmartScreen reputation and website
download buttons. Owner-facing summary of every deliberate decision, so
later phases don't re-litigate them.

## Product contract

Identical to macOS: download one installer, run it, get a tray app with a
guided first-run that either installs a local Dockerized backend or
connects to an existing instance — plus the same web container, inbox,
notifications, hotkey, and auto-updates.

## Decisions

### Installer: NSIS one-click `.exe`, not MSI

electron-updater — the auto-update machinery the mac app already ships —
supports NSIS but **not MSI**. An MSI would freeze every install at its
first version (or force a parallel manual-update story), which breaks the
"backend image pinned per app release" contract that auto-update keeps
honest. So the canonical artifact is the NSIS one-click installer
(`Syrus-Setup-<version>-<arch>.exe`): double-click, zero wizard pages,
per-user install under `%LocalAppData%\Programs\Syrus` (no admin), Start
menu + optional desktop shortcut, silent `/S` flag for fleet deployment.
An additional `msi` target can be added later purely for enterprise GPO
distribution, documented as "no auto-update; IT owns upgrades."

This is the one place we deliberately deviate from the literal ask
("download the .msi installer") — the .exe gives the smoother experience
the ask is actually about: it IS the self-install (no DMG-style
double-click-to-copy dance needed at all) and it keeps auto-update.

### Docker engine recommendation: Docker Desktop first, Podman Desktop offered

OrbStack is macOS-only, so Windows needs its own recommendation. Facts
that drive it:

- Any engine on Windows rides WSL2. `install.sh` (or its PowerShell port)
  talks to a Docker-API socket exposed to Windows.
- **Docker Desktop** exposes `docker.exe` + the named pipe natively,
  `docker compose` included — the compose file works unchanged. License:
  free for small orgs/personal use; paid for large employers.
- **Podman Desktop** is fully open source. `podman compose` drives our
  compose file via podman's Docker-compatible socket; detection is
  slightly different (machine must be started, socket must be enabled).

Recommendation shown to users: Docker Desktop as the default happy path
(most reliable compose semantics), Podman Desktop as the explicitly
supported open-source alternative — mirroring how macOS recommends
OrbStack while supporting Docker Desktop/Colima. Detection order:
`docker.exe` on PATH or Docker Desktop's install dir → podman machine
with docker socket → offer downloads of both.

### Local backend install: PowerShell port, not WSL-bash

`install.sh` assumes bash, Homebrew, `open -a` — none exist on Windows.
Two options were considered:

1. Run install.sh inside WSL (`wsl.exe bash install.sh`) — tempting but
   wrong: it puts Syrus's state inside a WSL distro the user may reset,
   requires a distro to exist (Docker Desktop's special distros don't
   count), and doubles the failure surface.
2. **Port the installer to PowerShell** (`install.ps1`) implementing the
   same machine interface (`--json` progress events, exit codes, `--image`,
   `--target-dir`, `--port`) so `installerDriver.ts` stays engine-agnostic.
   State lives at `%USERPROFILE%\.syrus\local\` — the SAME path expression
   as every other platform (settings.ts localStateDir is unbranched on
   purpose): it keeps the shared Syrus home next to `.syrus\credentials`
   and preserves migrateBackendConfig's adopt-a-CLI-install semantics.
   (`%LocalAppData%\Syrus\` is instead reserved for the CLI binary at
   `%LocalAppData%\Syrus\bin\`, which must live OUTSIDE the NSIS `$INSTDIR`
   so app auto-updates can't delete it.)

Option 2 is the plan. The compose file and image are identical; only the
bootstrap script differs. The driver contract (JSON events over stdout)
is already covered by CI's machine-interface tests, which the PowerShell
port must pass verbatim (same events, same exit codes).

### Tray: same paradigm, Windows-native details

Electron's `Tray` works on Windows; the existing code already branches
correctly (badged icon instead of macOS title text, taskbar-relative
popover positioning). Windows specifics:

- Icon: dedicated 32×32-optimized `.ico` variant (template images don't
  exist on Windows; use the full-color mark).
- The tray lives in the notification-area overflow by default; first-run
  copy tells users they can drag it out. No dock equivalent — the window
  simply appears in the taskbar when open (`app.dock` calls are already
  darwin-gated).
- Hotkey stays `CommandOrControl+Shift+S` → Ctrl+Shift+S (no conflict
  with Windows 11 snipping, which is Win+Shift+S).

### Windows on ARM

UTM/Parallels users and ARM laptops run Windows 11 ARM64. Electron ships
win32-arm64; the NSIS target builds per-arch. We ship x64 **and** arm64
installers (stable aliases `Syrus-Setup.exe` / `Syrus-Setup-arm64.exe`).
The backend image is already multi-arch (amd64/arm64), so a local install
under an ARM64 Docker Desktop/WSL2 works too.

### Auto-update

electron-updater's NSIS path (`latest.yml` + installer + blockmap on the
same GitHub Releases feed). No zip artifact needed on Windows. Unsigned
builds auto-update fine; SmartScreen friction at first install goes away
once we sign (below).

### Code signing (researched July 2026)

The "Apple Developer Program equivalent" is **Azure Artifact Signing**
(formerly Trusted Signing): $9.99/month Basic tier, and individual
developers in the US/Canada ARE eligible for identity validation
(government photo ID + selfie; the 3-year-organization requirement from
the 2025 preview lockdown is gone). Strictly, Microsoft says no
certificate guarantees zero SmartScreen warnings — but indie reports
(Electron's own docs, Zettlr, melatonin.dev) consistently show Artifact
Signing reputation attaches to the validated identity and the "Windows
protected your PC" interstitial disappears immediately or within days,
persisting across releases. EV certs lost their instant-reputation
privilege in March 2024, so the EV premium buys nothing here anymore.

Wiring: electron-builder 26 supports it first-class via
`win.azureSignOptions` (`publisherName` must match the cert profile CN
byte-for-byte, plus `endpoint`, `codeSigningAccountName`,
`certificateProfileName`) with `AZURE_TENANT_ID` / `AZURE_CLIENT_ID` /
`AZURE_CLIENT_SECRET` env — but it drives the Invoke-TrustedSigning
PowerShell module, so the **Windows release job must run on a
`windows-latest` runner** (cross-signing from macOS arrives with
electron-builder v27's signtool-dlib path). Identity validation expires
every 2 years — calendar it. Setup: a pay-as-you-go Azure subscription
whose billing name/address exactly match the government ID, an Artifact
Signing account + identity validation + certificate profile, and a
service principal for CI.

Fallbacks for non-US/CA individuals: Certum Open Source Code Signing in
the Cloud (~$58, SimplySign; headless CI is hacky), SSL.com IV +
eSigner. Both still ride the slower OV-style reputation ramp.

**Setup runbook and exact repo secrets: [`windows-signing.md`](./windows-signing.md).**
`.github/workflows/sign-windows-test.yml` is the manual-dispatch proving
ground for the Azure chain — it validates certificate profile, identity,
and signing without cutting a release. The live `build-windows` job in
`release.yml` depends on the same configuration and refuses to
publish unsigned artifacts.

### Field notes: the "Missing Shortcut" failure (July 2026 UTM test)

First real ARM64 guest run ended with Windows' "Missing Shortcut —
Windows is searching for Syrus.exe" dialog. Root-cause analysis:
electron-builder's one-click installer launches the app via the freshly
created Start Menu shortcut (`StdUtils.ExecShellAsUser` on
`$launchLink`, installSection.nsh) and never re-checks that the target
executable still exists. Mitigation shipped at the time:
`build/installer.nsh` customInstall verifies `$INSTDIR\Syrus.exe`
exists after extraction and fails with actionable guidance instead of
the shell dialog.

**Actual root cause (confirmed July 2026, after a second field round
falsely implicated Defender):** electron-builder 26.15.0–26.15.5
packed arm64 NSIS payloads with 7-Zip 24.09's ARM64 branch-converter
filter on PE entries. The install-time Nsis7z decoder cannot decode
that coder and **silently skips every `.exe`/`.dll`** (the plugin
discards its own error status; the NSIS error flag never sets), while
plain-LZMA2 data files extract normally. Signature: install dir has
all `.pak`/`.bin`/`.json` files plus `Uninstall Syrus.exe`, zero other
PE files; Defender Protection history, `Get-MpThreatDetection`, and
event log 1116/1117 all empty; hash-verified installer; 100%
reproducible. electron-userland/electron-builder#9983, fixed in
26.15.6 (pins the payload filter to BCJ, which the decoder handles) —
`windows_scaffold_spec.rb` pins our floor there. Confirm a payload is
decodable with `7zz l -slt app-arm64.7z`: PE entries must NOT show
`ARM64` in their Method field.

Diagnosis checklist for a failing guest, in order: (1) data-files-only
install dir + empty Protection history → the #9983 class (verify the
builder version and payload Method fields); (2) populated-but-no-exe
WITH a Protection history / `Get-MpThreatDetection` entry → Defender
quarantine of the unsigned exe (Wacatac.B!ml is the classic false
positive; the real fix is signing, above); (3) only
`Uninstall Syrus.exe` present → extraction never ran (check the guest
really is native ARM64 Windows — an arm64-only package on x64 extracts
nothing, silently). Note antivirus exclusions must cover
`%LocalAppData%\Temp` too, not just the install dir — the payload is
staged in `$PLUGINSDIR\7z-out` under TEMP before being copied.

## Phases

1. **Foundation (shipped).** `icon.ico` + generator script; NSIS config in
   electron-builder.yml; platform seams (`titleBarStyle`, bash spawns
   gated); Windows runtime detection returning download recommendations
   (Docker Desktop, Podman Desktop); Welcome screen offers connect-mode.
2. **Local install (shipped July 2026).** `install.ps1` implements the
   identical machine interface (NDJSON events, 8 step ids, exit codes —
   spec/desktop/install_parity_spec.rb keeps the two scripts' contract
   strings in lockstep), driven by the same installerDriver through a
   platform-selected interpreter (installPaths.installerCommand: bash vs
   `powershell.exe -File`); cancel kills the tree via `taskkill /T` (no
   POSIX process groups on Windows); the image-update path
   (backendLifecycle.updateBackend) shares the seam; Welcome's local card
   is a real choice on Windows; RuntimeSetup recommends Docker Desktop
   with the download CTA per-platform, preceded by a WSL 2 preflight —
   when WSL is absent, a one-click elevated `wsl --install
   --no-distribution` runs first, with restart-resume copy (reopening
   Syrus picks the flow back up after the reboot).
   The bundled CLI ships as `syrus-win32-{x64,arm64}.exe`, installs to
   `%LocalAppData%\Syrus\bin` (outside the NSIS `$INSTDIR`, which
   auto-updates replace wholesale) and joins the per-user PATH via the
   registry (raw HKCU\Environment write + WM_SETTINGCHANGE broadcast —
   never setx). Also shipped from the parity pass: AUMID
   (`app.setAppUserModelId`) so notifications display, work-area-aware
   popover placement (bottom taskbars open upward), full-color tray icon
   with a bitmap-drawn unread dot (nativeImage can't rasterize SVG), and
   instance-takeover on win32.
   The `build-windows` job also exists now
   (release.yml; hard-requires the Azure signing config — it
   never publishes unsigned artifacts).
   Still open from this phase: `podman machine start`/`podman compose`
   support (Docker Desktop-only for now — exit 12/10 copy says so).
3. **Parity polish.** Windows toast actions, Start-with-Windows login
   item (`setLoginItemSettings`), first-run "pin the tray icon" hint,
   per-monitor DPI QA on a real multi-monitor machine.
4. **Signing + GA.** Authenticode signing in CI (runbook:
   docs/windows-signing.md), SmartScreen reputation, the `build-windows`
   release job with stable aliases, website download buttons out of beta.

## Testing without nested virtualization (Windows 11 on UTM)

UTM on Apple Silicon cannot run WSL2/Docker inside the guest (no nested
virtualization). The test plan splits what runs where:

- **Backend on the Mac host.** `bin/build-local-image && SYRUS_PORT=3000
  bin/compose-up` (or the mac desktop app's own local install). Bind is
  0.0.0.0, so the guest reaches it at the host's IP — with UTM's default
  shared network, `http://<mac-ip>:3000`; UTM emulated VLAN also exposes
  the gateway alias `10.0.2.2`.
- **Windows app in the guest** (arm64 NSIS build): exercise install →
  tray → first-run → **Connect to existing Syrus** → `http://<mac-ip>:3000`
  (URL-only; sign in inside the app window and the tray token mints
  itself — see docs/desktop-auth-plan.md; non-admin accounts would use
  the manual URL+token form in Preferences instead) → web container,
  inbox, notifications, hotkey, auto-update (point SYRUS_UPDATE_FEED at
  a draft release).
- **What this covers:** everything except the local-Docker install path —
  installer UX, tray paradigm, web container, token provisioning,
  update loop, ARM64 build health.
- **Local-install path** is tested in CI (PowerShell installer against
  the machine-interface suite on windows-latest, which does have WSL2)
  plus, eventually, one real x64 Windows box (or a cloud VM like an Azure
  D-series with nested virt) for an end-to-end dress rehearsal.

## Open questions (deliberately deferred)

- Whether the web container should use a custom titlebar on Windows to
  match the mac hiddenInset look, or keep the native frame (phase 3).
- MSI-for-enterprise packaging (post-GA, on demand).
- Winget manifest publication once signing lands.
