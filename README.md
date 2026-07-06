# Syrus

> *Bis dat qui cito dat.*
> He gives twice who gives quickly. — Publilius Syrus

**Syrus lets a team put coding agents to work on a shared codebase —
conversationally, concurrently, and under one reviewed workflow.**

You describe what you want in a Syrus chat — a feature, a refactor, a whole
initiative — and Syrus turns the conversation into work. It breaks large
changes into **Epics** (a stack of smaller, ordered pieces), runs coding
agents (Claude or Codex) to implement each one, and lands the result as
reviewed pull requests. You do the reviewing; Syrus does everything between
the idea and the merge.

**Why not just run Claude or Codex yourself?** A single agent can't safely
work a repository the way a team needs to. Syrus runs **many changes at once
on the same codebase** — even changes that touch the same files — without
corrupting it: every change gets an isolated workspace, Syrus rebases them
against each other automatically, and it ships them as **stacked pull
requests** that review and land cleanly in order.

And it imposes the **same production-grade workflow on every change** —
branch, prepare, implement, run your graders, write a test plan, open a PR,
rebase, land — so the process is deterministic instead of whatever the agent
improvises on a given run. That means consistent results, fewer tokens burned
on the agent re-deriving what to do next, and a hard guardrail: **nothing
reaches your main branch without a human review.**

Syrus is multi-user and self-hosted. It tracks who asked for what, what every
agent did, and what it cost — running on your own infrastructure, pointed at
your own repositories, using your own GitHub and Claude/Codex credentials.

---

## Install

There are two things to run: the **Syrus backend** (the app itself) and,
optionally, a **client** to drive it (the desktop app or the CLI). The
easiest path installs all of it for you.

### Desktop app — the easy path (macOS; Windows in beta)

The desktop app installs and manages a local Syrus backend for you (or
connects to one your team already runs), puts the full web UI in a native
window, and adds a menu-bar inbox. It's batteries-included: it also installs
the `syrus` CLI and keeps it updated, and you sign in with your email and
password — no API keys to copy.

**macOS** — one universal download for both Apple Silicon and Intel:
**[Syrus.dmg](https://github.com/tkadauke/syrus/releases/latest/download/Syrus.dmg)**.
Open it and double-click Syrus in the disk image — it installs itself to
Applications and launches; the first-run setup handles the Docker backend. No
terminal required.

That link always points at the newest signed build; you can also browse every
release and its checksums on the
[Releases page](https://github.com/tkadauke/syrus/releases).

**Windows** is in beta. It installs and runs Syrus the same way (on Docker
Desktop, with a guided WSL 2 setup). Signed installers land on the
[releases page](https://github.com/tkadauke/syrus/releases) once code
signing goes live; until then, build it from source (see
[the desktop docs](website/src/content/docs/desktop.md)).

Full details: **[desktop app docs](website/src/content/docs/desktop.md)**.

### Run the backend yourself (Docker, no desktop app)

To run Syrus on a server, or without the desktop app, clone the repo and run
the Docker installer. It installs a container runtime if you don't have one,
generates secrets, pulls the prebuilt image, and starts the stack:

```bash
git clone git@github.com:tkadauke/syrus.git    # no SSH key? gh repo clone tkadauke/syrus
cd syrus
./install.sh --docker
```

Open **http://localhost:3000**. The first account you create becomes the
admin, and a first-run wizard walks you through GitHub credentials, the
agent (Claude or Codex), your first repository, and a guided chat to land
your first change. Your data lives in a Docker volume and survives restarts.

No Ruby, Node, or Go required — the image (`ghcr.io/tkadauke/syrus-backend`)
is public. See [Docker Compose deployment](website/src/content/docs/deployment/docker-compose.md)
for pinning versions, adding OS packages, and building the image yourself,
and [the deployment docs](website/src/content/docs/deployment/) for
Kubernetes.

### The `syrus` CLI (for terminals and servers)

Desktop app users already have the CLI — it's installed and kept current
automatically. On a server or a machine without the app, download the
archive for your platform from the
[Releases page](https://github.com/tkadauke/syrus/releases):

```bash
# Apple Silicon macOS shown; pick the matching OS/arch and version.
curl -LO https://github.com/tkadauke/syrus/releases/download/v0.4.0/syrus_v0.4.0_darwin_arm64.tar.gz
tar -xzf syrus_v0.4.0_darwin_arm64.tar.gz
install -d ~/.local/bin && install syrus_v0.4.0_darwin_arm64/syrus ~/.local/bin/syrus

syrus login   # enter your instance URL + an API token from the web UI's Credentials page
```

Run `syrus` with no arguments for terminal chat, or `syrus inbox` to review
work. Full reference: [CLI docs](website/src/content/docs/cli.md).

---

## What you get

- **Chat that ships code.** Describe what you want in a Syrus chat and it
  proposes the work — Jobs and Epics — for you to confirm. Chat reads the
  repo to plan; implementation always runs in isolated workspaces, never in
  chat.
- **Epics for big changes.** A feature or initiative becomes an Epic: a
  dependency-ordered stack of smaller Jobs that Syrus implements, rebases
  against each other, and lands in order (optionally all-or-nothing through a
  merge train). This is the path from a customer ticket to a merged solution.
- **A deterministic pipeline.** Every change runs the same steps — prepare,
  implement, run your graders, summarize, write a reviewer test plan, open a
  PR — and PR feedback, failing CI checks, and transient errors feed back to
  the agent automatically.
- **A landing queue with a human gate.** Approve a PR and Syrus rebases it,
  re-runs required checks, and merges it — serialized so dependent work lands
  in order. Nothing merges to your main branch without approval.
- **Concurrency without corruption.** Every Job gets its own workspace and
  Syrus rebases branches automatically (force-push with lease), so many
  changes can be in flight on one repository at once.
- **Team-aware.** Multi-user with per-user encrypted credentials, Job
  ownership and claims, an admin API, and a spending dashboard that breaks
  cost down by person, Epic, and repository.

Work can also enter other ways: label a GitHub issue, attach a recurring cron
prompt to a repository, or create a one-off Job from a prompt. Everything runs
on polling — Syrus reaches out to GitHub on a schedule, with no inbound
webhooks to configure.

---

## For developers and operators

Everything below is for running Syrus from source, hacking on it, or
deploying it to production. If you just want to *use* Syrus, the Install
section above is all you need.

### Run from source (macOS, bare metal)

The full from-nothing dev setup on a Mac with Homebrew. Every command is
copy-pasteable, and `bin/setup` is idempotent, so re-running is safe. You'll
end up with Ruby 3.2.3, Node + npm, Go, libvips, the MySQL client libraries,
and the Claude Code CLI. Local dev uses **SQLite** — you do not run a MySQL
server and need no master key; MySQL client libs only appear so the
production `mysql2` gem can compile.

**Fast path — one command.** The installer does every step below (Xcode CLT,
Homebrew, deps, Claude CLI, rbenv + Ruby, `bin/setup`, the `syrus` CLI on
your PATH):

```bash
git clone git@github.com:tkadauke/syrus.git    # no SSH key? gh repo clone tkadauke/syrus
cd syrus
./install.sh --bare-metal      # add --start to launch and open the browser
```

Then `bin/dev` and open **http://localhost:3000** — the first account
becomes the admin. Prefer to do it by hand, or hit a snag? The manual steps
follow; the installer runs exactly these.

<details>
<summary><strong>Manual walkthrough (the same steps, by hand)</strong></summary>

#### 1. Xcode Command Line Tools + Homebrew

```bash
xcode-select --install || true

if ! command -v brew >/dev/null; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Apple Silicon path shown; on Intel, brew lives at /usr/local.
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

#### 2. System dependencies

```bash
brew update
# rbenv/ruby-build: Ruby. node: JS + Claude CLI. go: builds the Syrus CLI.
# vips: image processing. mysql: client libs so the mysql2 gem compiles.
brew install rbenv ruby-build node go vips mysql
brew install openssl@3 readline libyaml   # libraries Ruby links against

# The worker shells out to `claude` to run Jobs and chats.
npm install -g @anthropic-ai/claude-code
```

> If `bundle install` later fails to build `mysql2`:
> `bundle config set --local build.mysql2 "--with-mysql-config=$(brew --prefix mysql)/bin/mysql_config"`
> and re-run `bin/setup`.

#### 3. Ruby 3.2.3 with rbenv

```bash
echo 'eval "$(rbenv init - zsh)"' >> ~/.zshrc
eval "$(rbenv init - zsh)"
rbenv install 3.2.3 --skip-existing
rbenv global 3.2.3
ruby -v   # ruby 3.2.3
```

#### 4. Clone

```bash
git clone git@github.com:tkadauke/syrus.git   # no SSH key? gh repo clone tkadauke/syrus
cd syrus
```

#### 5. Set up and start

```bash
bin/setup    # gems + JS deps, build the Go CLI, prepare the SQLite DBs
bin/dev      # web + worker + tailwind + JS watch, on port 3000
```

</details>

Open **http://localhost:3000**. The **first account becomes the admin**, and
the first-run wizard walks you through GitHub credentials (a classic PAT +
the GitHub App), the agent, a repository, and a guided first Epic. The
**Configure agent** step handles Claude (reuse an existing `claude` login or
authorize one — needs a Claude Pro/Max/Team/Enterprise plan) or Codex.

### Handy commands

```bash
bin/dev          # foreman: web (rails s) + worker (bin/jobs) + tailwind + JS watch
bin/rspec        # Ruby test suite
bin/test-react   # React/Vitest suite + TypeScript typecheck
bin/test         # Ruby and React suites together
bin/test-docker  # integration tests against the Docker image (isolated stack)
```

`bin/test-docker` brings up a throwaway Compose stack (its own project,
volume, and host port) and asserts the database, file uploads, the worker
draining jobs, the dev toolchain, and the MCP sidecar boot. Pass
`SYRUS_IMAGE=…` to test a specific tag.

### Build or customize the Docker image

`./install.sh --docker` pulls the prebuilt image. To build it yourself — to
change Syrus source or add OS packages your repos' build/grader commands need
— use `bin/compose-up`, and set `EXTRA_APT_PACKAGES` for extra apt packages.
Details and the registry BuildKit cache flags are in
[Docker Compose deployment](website/src/content/docs/deployment/docker-compose.md).
`bin/publish-image` publishes the host architecture by default; pass
`--multi-arch` for both `linux/amd64` and `linux/arm64`.

### Build the clients from source

```bash
bin/setup --install-cli            # builds cli/bin/syrus and installs it on PATH
# or, from cli/:  make install PREFIX=~/.local

npm --prefix desktop install
npm --prefix desktop run dev       # desktop app, local development
npm --prefix desktop run build     # packaged app in desktop/out
```

Maintainers cut releases from CI — **Actions → "Release"**, pick a version
bump, and the pipeline builds, signs, and publishes the CLI, both desktop
apps, and the backend image atomically (see [`docs/releasing.md`](docs/releasing.md)).
The `bin/release*` scripts are local build/verify tools only:

```bash
bin/release v0.0.0-local --desktop   # build desktop artifacts locally, no publish
bin/publish-image X.Y.Z              # build + test + push the image (local/fork)
bin/release-notes v0.4.0             # preview Claude-written notes
```

### Production configuration

Production is driven by environment variables:

- `SYRUS_APP_HOST` — public app host for URL generation and mailer links.
- `SYRUS_ALLOWED_HOSTS` — comma-separated host allowlist (defaults to `SYRUS_APP_HOST`).
- `SYRUS_ASSUME_SSL` / `SYRUS_FORCE_SSL` — TLS behavior for proxied deployments (default `true`; `/up` is exempt).
- `SYRUS_GITHUB_REPO` — optional: this installation's own `owner/repo`; enables build-revision links (degrades to no link when unset).
- `SYRUS_BUG_REPORT_OWNER` — **required**: GitHub owner/org for in-app bug reports (expects an active `<owner>/syrus` repo).
- `SYRUS_MAILER_FROM` — sender address for application mail.
- `SMTP_*` — SMTP settings; without `SMTP_ADDRESS`, Rails keeps its default delivery.

Production uses MySQL and requires `RAILS_MASTER_KEY` (or the three Active
Record encryption keys). Migrations must be valid from an empty database.
See [the deployment docs](website/src/content/docs/deployment/) for
Kubernetes and Docker Compose specifics.

### How it works, and its limits

| Choice | Decision |
| --- | --- |
| Stack | Rails 8 + Solid Queue (MySQL or single-host SQLite in prod, SQLite in dev/test) · React + TypeScript via Vite · Go CLI |
| Trigger model | External polling for GitHub issues, PR feedback, CI failures, merge state, and scheduled tasks — no inbound webhooks |
| Auth | Multi-user; first signup = admin, then invite-only |
| Credentials | Per-user, encrypted at rest (GitHub token, Claude/Codex credentials, admin API token) |
| Workers | Separate container from the web app |
| Deploy | Kubernetes or Docker Compose |

**Security posture.** Syrus assumes trusted users operating on trusted
repositories. Agent runs execute in worker-managed per-Workflow workspaces
under `SYRUS_DATA_ROOT` — this keeps the agent out of your operator checkout,
but it is **not** a hardened sandbox for untrusted code. Run Syrus on
infrastructure you control, register repositories whose code and setup
commands you're willing to execute, scope GitHub tokens narrowly, and review
generated PRs before merging.

The MVP deliberately excludes inbound GitHub delivery, hosted multi-tenant
sandboxing, and out-of-band human escalation.

`CLAUDE.md` is the in-repo guide for coding agents working on Syrus itself;
`ROADMAP.md` tracks milestones.

### Operator controls

- **Skip prepare.** The `syrus-skip-prepare` label on a source issue starts a
  Job at implementation, bypassing broken prepare commands.
- **Scheduled tasks.** Cron tasks use five-field UTC expressions treated as
  hourly windows (the minute field is a per-task offset so tasks with the
  same schedule don't all fire on one tick).
- **Credentials.** Users replace GitHub and agent credentials from **My
  credentials**; admins generate, rotate, or revoke API tokens there too.
  Rotating invalidates the old token immediately.

## Naming

Named after [Publilius Syrus](https://en.wikipedia.org/wiki/Publilius_Syrus),
the 1st-century-BCE Roman writer whose *Sententiae* — a collection of
one-line maxims — were schoolbook material for over a millennium and seeded a
surprising number of phrases still in everyday use. He was a writer, the same
job the LLM does inside this harness, and his output outlived him by two
thousand years. That's the aspiration: small, durable text that compounds.
