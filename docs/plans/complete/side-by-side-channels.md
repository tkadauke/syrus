# Side-by-side channels: run a release and a test build simultaneously

_Status check 2026-09-19: complete. `desktop/electron/channel.ts` implements
the stable/test channel split and "Syrus Test" productName fork; `install.sh`
has `--project NAME`/`COMPOSE_PROJECT_NAME` and `SYRUS_BOOT_POLLING_PAUSED`;
the Go CLI resolves its profile from argv0 (`cli/internal/config/profile.go`).
Retained as design history._

## Problem

Syrus-develops-Syrus requires running a production (release) desktop app and a
test build (any non-release) on the same machine at the same time. Today that
is impossible by construction, at four independent layers:

1. **One bundle name.** Every build is `Syrus.app`, so a test DMG's
   self-install offers to REPLACE the production install
   (`selfInstall.ts` targets `path.basename(bundlePath)`).
2. **One single-instance lock.** Electron keys the lock on the userData dir,
   which derives from `productName: "Syrus"` — the second copy to launch hits
   the instance-takeover prompt and one of them quits (`main.ts` lock +
   `second-instance` handler).
3. **One backend stack.** Compose project `syrus`, state dir `~/.syrus/local`,
   volumes `syrus_syrus-data`/`syrus_syrus-search`, host port `3000` — all
   effectively hardcoded (three independent `syrus` project-name pins, a
   verbatim volume-name guard in `install.sh:309`, `-p syrus` in
   `backendLifecycle.ts:57` and `installerDriver.ts:658`).
4. **One credentials file + one CLI.** `~/.syrus/credentials` is shared by the
   app and the Go CLI (last writer wins; `tokenProvisioner.ts:83`'s
   different-instance guard then blocks the loser), and both apps
   content-hash-reinstall the same `~/.local/bin/syrus`.

## Design: one bit, `channel ∈ {stable, test}`, decided at build time

Every build is either **stable** (produced by the Release workflow) or
**test** (produced by the Test-build workflow, or built locally — the `0.0.0`
dev sentinel is test). The channel is baked at packaging time and drives every
namespaced resource. Naming aligns on the single word *test*, consistent with
the existing `X.Y.Z-test.N` versions and `test-*` image tags:

| Resource               | stable                       | test                              |
| ---------------------- | ---------------------------- | --------------------------------- |
| Product name / bundle  | `Syrus` / `Syrus.app`        | `Syrus Test` / `Syrus Test.app`   |
| macOS bundle id / AUMID| `app.syrus.desktop`          | `app.syrus.desktop.test`          |
| userData (settings)    | `…/Application Support/Syrus`| `…/Application Support/Syrus Test`|
| App icon / tray        | terracotta mark              | amber-badged mark + mac tray title `TEST` |
| Backend state dir      | `~/.syrus/local`             | `~/.syrus/local-test`             |
| Compose project        | `syrus`                      | `syrus-test`                      |
| Volumes                | `syrus_syrus-data`, `…-search` | `syrus-test_syrus-data`, `…-search` |
| Host port (default)    | `3000`                       | `3001`                            |
| Credentials file       | `~/.syrus/credentials`       | `~/.syrus/credentials.test`       |
| Global hotkey default  | `⌘⇧S`                        | `⌘⇧T`                             |
| Versions / image tags  | `X.Y.Z` / `:X.Y.Z`, `:latest`| `X.Y.Z-test.N` / `:test-*` (unchanged) |
| CLI binary             | `~/.local/bin/syrus`         | `~/.local/bin/syrus-test`         |

### What falls out for free once productName + appId fork

Confirmed against current code:

- **userData splits** (Electron derives it from the product name) → settings
  store, backendMode, window bounds, hotkey prefs all channel-local.
- **Single-instance lock splits** (keyed on userData) → cross-channel
  coexistence with zero code; same-channel keeps today's takeover prompt.
- **Self-install targets its own name** (`path.basename(bundlePath)`) → test
  installs over test, prod over prod. The version-aware replace dialog needs
  no changes.
- **Menu bar name, About panel, notifications** show `Syrus Test` via
  productName. DMG volume title already carries the `-test.N` version.
- **Auto-update invariants unchanged**: test builds keep `isPinnedTestBuild`
  (never self-update); stable's baked GitHub feed is untouched. Test builds
  don't stage feed files, so the `${productName}`-derived artifact names
  cannot collide with release assets.

### Runtime channel awareness

`desktop/electron/channel.ts` (pure, testable):
`channel(): "stable" | "test"` — reads the channel baked into
`resources/backend/manifest.json` (new `channel` field written by
`stage-backend-assets.mjs`), falling back to version shape
(`-test.N` or `0.0.0` ⇒ test). Consumers: credentials path, state-dir
default, hotkey default, tray title, `migrateBackendConfig` adoption guard,
`imageCleanup` tag-shape guard. The SPA learns the channel from the existing
`SyrusDesktop/<version>` UA token (regex `-test\.` / `0.0.0`) — no new IPC.

### Backend stack isolation (the real work)

Introduce a **stack identity tuple** `{stateDir, project, dataVolume, port}`
carried in `LocalInstall` (settings.ts) instead of constants:

- `install.sh` gains `--project NAME` (exported as `COMPOSE_PROJECT_NAME`,
  default `syrus`); the encryption-key volume guard at `install.sh:309`
  becomes `${PROJECT}_syrus-data`. `--port` and `--target-dir` already exist.
- Desktop threads the tuple through `backendLifecycle.ts` (`-p`),
  `installerDriver.ts` (DATA_VOLUME_NAME uses, wipeData `down -v`), the
  watchdog's data-gone diagnosis, and the Backend menu paths (which today
  bypass `getLocalInstall().stateDir`).
- `uninstall.sh` mirrors `--project` at its five pinned sites; the desktop
  uninstall passes its channel's tuple. Windows `install.ps1` gets the same
  parameter.
- `migrateBackendConfig` adopts `~/.syrus/local` ONLY on the stable channel
  (a test app must never adopt prod's stack).
- `imageCleanup.supersededSyrusImages` prunes only tags of the SAME channel
  shape as the pin being installed (`test-*` vs semver) so one channel's
  update can't delete the other's image.

Deliberate consequence: the two stacks are fully isolated Docker projects
with separate databases and encryption keys. Test-channel experiments cannot
corrupt production data; each channel does one credential setup, once.

### Two-pollers footgun

Two backends polling the same GitHub repos with the same PAT would BOTH pick
up `syrus`-labeled issues (double Jobs, double PRs). Mitigation: the test
channel's `.env` gets `SYRUS_BOOT_POLLING_PAUSED=1`; the backend reads it
once at first boot (fresh DB only) and seeds `AppSetting.polling_paused =
true`. The operator un-pauses from the admin UI when they intend the test
stack to work real repos. One-line backend change, no migration.

### Visual indicators (test builds must look different at every distance)

- **App icon**: committed `desktop/build/icon-test.png` — the winged-stylus
  mark re-tinted amber with a "TEST" ribbon; `make-ico.mjs` generates the
  matching `.ico`. Dock, Cmd-Tab, Finder all differ at a glance.
- **DMG**: background variant text renders "Syrus Test" (parameterize
  `render-dmg-background.mjs`); volume title already shows `-test.N`.
- **Tray**: macOS `tray.setTitle("TEST")` next to the template icon (cheap,
  extremely visible); Windows uses the amber icon variant.
- **In-app**: amber `TonePill` "TEST BUILD" beside `SyrusBrand` in
  `AppChromeV2`, and `BuildBadge` highlights `-test.N` versions. Window title
  suffix " — Test".

### CI threading

`_build-app.yml` gains `channel: release | test` (default `release`) —
"every caller difference is an input" is the module's documented rule.
The desktop build steps map it to env (`PRODUCT`, `APP_ID`, icon paths) and
pass electron-builder CLI overrides (`-c.appId -c.productName -c.mac.icon
-c.win.icon -c.dmg.title -c.nsis.shortcutName`), following the existing
`-c.win.azureSignOptions.*` precedent. The ~12 hardcoded `Syrus` occurrences
in the verify/stage steps become `$PRODUCT`. `release.yml` passes
`channel: release`; `test-build.yml` passes `channel: test`; local
`npm --prefix desktop run build` defaults to test unless
`SYRUS_RELEASE_BUILD=1`.

### CLI story (v1) — channel-suffixed binaries, self-aware by name

Working on CLI features and cutting a test build must produce a testable
CLI, so the test channel DOES manage one: the stable app installs
`~/.local/bin/syrus`, the test app installs `~/.local/bin/syrus-test` — the
same content-hash reinstall mechanics, each channel against its own
filename, so the two apps never reinstall over each other and every test
build ships its CLI.

One Go binary, no CI build variant: profile resolution is `--profile` flag >
`SYRUS_PROFILE` env > `argv[0]` basename (`syrus-test` → test) > `stable`
(BusyBox-style — the identical artifact behaves correctly under either
name). The profile selects the credentials file
(`~/.syrus/credentials[.test]`), so `syrus-test jobs` talks to the test
stack with the test-built CLI, while `syrus --profile test` runs the STABLE
binary against the test backend when the thing under test is the backend.
The Claude-skill offer stays stable-only for v1 (the skill invokes
`syrus`).

### Migration

None needed. Existing prod installs, stack, and credentials are exactly the
stable channel's resources. The first new-scheme test build installs as
`Syrus Test.app` beside whatever exists and provisions its own fresh stack on
port 3001. (Machines that installed a test DMG *as* `Syrus.app` under the old
scheme simply keep it until the next release install replaces it.)

## Phasing — three stacked PRs

1. **Stack identity tuple** (backend-agnostic parameterization): install.sh
   `--project` + volume-guard fix, `LocalInstall` tuple threading, uninstall
   + Windows parity, `SYRUS_BOOT_POLLING_PAUSED`. Zero behavior change for
   existing installs (defaults preserve today's values).
2. **Desktop channel identity**: `channel.ts`, electron-builder per-channel
   overrides + icons + AUMID, credentials path fork, migrate/adopt guards,
   imageCleanup tag-shape guard, hotkey default, tray/DMG/in-app indicators.
3. **CI + docs**: `channel` input through `_build-app.yml` + callers, verify
   steps de-hardcoded, spec updates (packaging, test_build, auto_update,
   uninstall, windows scaffold, cli_install), `docs/releasing.md` +
   website-docs audit note.

## Spec surface (budgeted up front)

`packaging_spec` (appId/productName/dmg pins become channel-aware),
`test_build_spec` + `auto_update_spec` (channel input + artifact names),
`web_container_spec` (manifest key list gains `channel`), `uninstall_spec`
(`/Syrus.app` leaf), `windows_scaffold_spec` (appId), `cli_install_spec`
(channel-suffixed install target), plus Go tests for argv0/env/flag profile
resolution and new unit coverage for `channel.ts`, the stack
tuple, and install.sh `--project` (source pins).
