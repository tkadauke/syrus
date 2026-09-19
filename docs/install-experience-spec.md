# The install experience, end to end

The authoritative map of every way Syrus arrives on a machine, what each
path installs, and what stays true afterwards. When a flow changes, this
file changes in the same PR — it is the contract the onboarding, updater,
CLI, and skill code implement. Sibling docs: `desktop-auth-plan.md` (why
tokens work the way they do), `windows-desktop-plan.md` (Windows port
history), `cli-desktop-plan.md` (CLI distribution history),
`releasing.md` (how artifacts are produced).

## The batteries-included principle

A Syrus install is three things, and a user should never have to know
that: **the app**, **the backend** (local Docker stack or a remote
instance), and **the CLI**. All three are always present and always
current — the CLI is product plumbing (the tray's Checkout button runs
it), not an optional extra. The only genuinely optional piece is the
**Claude Code skill**, because it writes into a third-party tool's
config — that one is offered, once, and only when such a tool is
actually present.

Invariants (each mapped to its enforcement below):

- **I1. The CLI is always installed.** The app installs it silently on
  first run and re-installs whenever the bundled copy differs from the
  installed one (content hash — the binary carries no version command).
- **I2. The CLI updates when the app updates.** Same mechanism: the
  freshness check runs on every launch, and an app update relaunches the
  app with a new bundled binary.
- **I3. Signing into Syrus signs in the CLI.** One credentials file
  (`~/.syrus/credentials`), written by the app's token provisioning and
  read by both; 401-healing re-mints it when a backend is rebuilt.
- **I4. The skill is offered, never imposed** — once, only when Claude
  Code (or Codex) is detected on the machine, and it tracks the CLI
  binary afterwards (a refreshed CLI re-writes an installed skill).

## Entry points

| # | Path | Platform | What runs |
|---|------|----------|-----------|
| E1 | DMG download → double-click Syrus in the image | macOS | self-installs to `/Applications` (`~/Applications` without admin rights; asks before replacing an existing install), relaunches, onboarding |
| E2 | NSIS `Syrus-Setup*.exe` one-click | Windows | installs to `%LocalAppData%\Programs\syrus-desktop`, launches, onboarding |
| E3 | App auto-update (electron-updater) | both | new app version relaunches; backend pin + CLI freshness checks run |
| E4 | Repo clone + `install.sh --docker` / `bin/setup` | dev/ops | CLI via `bin/setup` (optionally `--install-cli`); no app |

E5 (a standalone `curl \| sh` one-liner, no local clone) does **not** exist
today and nothing on the website links to one — see Known non-goals below.

## First-run onboarding (E1/E2), state by state

Welcome → choose:

- **Install locally** → precheck (in order): adopt a healthy foreign
  Syrus on the port → guided runtime acquisition (macOS: OrbStack;
  Windows: one-click elevated WSL 2 install when WSL is absent, then
  Docker Desktop; both note that a Windows restart resumes the flow on
  relaunch — precheck re-derives everything) → adopt-existing data
  volume (encryption-key guard) → port conflict → `install.sh` /
  `install.ps1` over the NDJSON machine interface → done.
- **Connect to existing** → URL-only form with an honest live probe
  (green = a Syrus answered; port guidance only on failure) → done.

**Done** (either mode) → app window opens → user signs in (or creates
the first account) → token provisioning writes `~/.syrus/credentials`
(I3) → tray works.

**CLI (I1):** installed silently by the app at launch — no dialog, no
choice, exactly like the backend assets. macOS: `~/.local/bin/syrus`.
Windows: `%LocalAppData%\Syrus\bin\syrus.exe` + per-user PATH registry
entry. Failure is non-fatal and self-heals on the next launch; the tray
shows its install banner only if the CLI is genuinely absent afterwards.

**Skill (I4):** after onboarding completes and credentials exist, IF
`~/.claude` or `~/.codex` exists and the skill was never offered → one
native dialog ("Claude Code detected — add the Syrus skill?"). Accepting
runs `syrus skill install`. Also available any time from Preferences.

## Updates (E3), what refreshes when

| Piece | Mechanism | Cadence |
|-------|-----------|---------|
| App | electron-updater (GitHub feed; NSIS/Squirrel) | checked ~6h, applied on restart |
| Backend image | manifest pin in app resources → update offer re-runs the bundled installer | next launch after app update |
| CLI | content-hash check of bundled vs installed binary → silent reinstall | **every launch** (I2) |
| Skill | re-written by the CLI reinstall when previously installed | rides CLI updates |
| Credentials | untouched by updates; 401-healing only | as needed (I3) |

## CLI acquisition matrix

| Situation | How the CLI gets there |
|-----------|------------------------|
| Desktop app user (any platform) | automatic at launch (I1/I2) |
| Repo clone dev | `bin/setup` builds it; `--install-cli` installs |
| CLI vanished mid-session (manual delete) | tray banner one-click; next launch reinstalls anyway |
| Non-admin on shared instance | CLI installs fine; token via Preferences manual form |

## Decision log

- **CLI is silent, skill is asked.** The binary in the user's own
  application-support area is product plumbing; a file inside another
  tool's config directory (`~/.claude/skills/`) warrants one explicit
  yes. (July 2026 field feedback: the previous opt-in CLI dialog made
  "batteries included" false — a user could decline and lose Checkout.)
- **Freshness = content hash, not version.** The Go binary ships no
  version command, and a hash can't lie about dev builds; hashing two
  ~20 MB files at launch costs milliseconds and only on mismatch does
  any work happen.
- **Windows CLI home is outside the NSIS `$INSTDIR`** so app updates
  (which replace that directory wholesale) can't delete it; the launch
  check would resurrect it anyway, but surviving is cleaner than
  resurrecting.
- **Skill detection is directory-based** (`~/.claude`, `~/.codex`), not
  PATH-based: GUI apps see a minimal PATH on macOS, and the config dir
  is what the skill actually integrates with.
- **The skill offer keys on agent presence, not on platform.** Codex
  detection triggers the same offer — the SKILL.md is agent-agnostic
  ("skills" are read by Claude Code today; Codex support can follow the
  same file).

## Gaps closed in the July 2026 round (was → is)

1. CLI was an opt-in dialog after onboarding → silent auto-install at
   launch (I1).
2. Nothing refreshed an installed CLI after app updates → per-launch
   hash check (I2).
3. Skill offer appeared for every user, agent tools present or not →
   offered only when `~/.claude`/`~/.codex` exists, and the dialog is
   now about the skill alone (I4).
4. A previously installed skill went stale as the CLI evolved → CLI
   refresh re-runs `skill install` when the skill file exists.

## Known non-goals (revisit on demand)

- Uninstall does not remove `~/.syrus` or the CLI (user data + shared
  home; documented in the website uninstall section).
- No CLI on PATH for `sudo`/system shells (per-user install by design).
- Homebrew/winget distribution — the app is the channel.
- **Standalone curl install (formerly listed as E5).** `install.sh` does
  `cd "$(dirname "$0")"` and then reads `docker-compose.yml` and
  `compose.env.example` from that same directory — it assumes those sibling
  files are already on disk. That's true for a git clone (E4) and for the
  desktop app's bundled Resources dir (which drives it with `--target-dir`),
  but a bare `curl -fsSL .../install.sh | sh` has nothing to fetch it against
  and doesn't work. Building that path for real would mean teaching
  `install.sh` to fetch its own sibling files (e.g. from a release tag)
  before doing anything else; until then, the website should only ever link
  to the documented clone-first flow (E4 / the Docker Compose deployment
  doc), never to a bare curl one-liner.
