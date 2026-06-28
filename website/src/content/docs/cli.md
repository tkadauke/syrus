---
title: Syrus CLI
description: Install, authenticate, chat, review, and manage Syrus work from the terminal.
---

# Syrus CLI

The Syrus CLI is a standalone Go binary under `cli/`. It talks to the
same app and admin JSON APIs as the React UI, but keeps the common
operator loop close to the checkout: chat with Syrus, review inbox items,
open PRs, check out Job branches, and print test plans.

## Build

`bin/setup` builds the CLI automatically as part of the normal dev
setup (skipped with a notice if Go isn't on your `PATH`). Pass
`--install-cli` to also copy the binary onto your `PATH`, and
`--skip-cli` to skip the CLI entirely:

```bash
bin/setup                          # builds cli/bin/syrus
bin/setup --install-cli            # also installs to /usr/local/bin/syrus
PREFIX=~/.local bin/setup --install-cli   # install elsewhere
```

To build (or install) the binary on its own, from the repository:

```bash
cd cli
make build                 # writes bin/syrus
make install               # installs to /usr/local/bin (honors PREFIX)
```

The build writes `bin/syrus`. Put that binary on your `PATH`, or run it
directly from `cli/bin/syrus`.

## Log In

Run `syrus login` once:

```bash
syrus login
```

Generate or rotate the token from **Credentials** in the Syrus web UI;
the token is shown once. `syrus login` asks for the Syrus instance URL
and that API token, then writes
`~/.syrus/credentials`:

```text
url=https://syrus.example.com
token=your-api-token
```

Syrus Desktop reads and writes the same credentials file. If you have
already run `syrus login`, the desktop app starts authenticated. If the
file is missing or incomplete, the desktop app prompts for the same URL
and API token, validates them against `/api/v1/app/bootstrap`, and saves
the file for both desktop and CLI use. While signed in, the desktop main
process keeps a live connection to the user's app events so native
notifications, tray badge state, and renderer views can react without
opening separate WebSocket connections. `notification_created` events show
OS-level banners using the notification body from Syrus; clicking a banner
opens the matching Job page or pull request in the browser.

On macOS, Syrus Desktop runs as a menubar app without a Dock icon. The
tray icon shows an unread notification badge when notifications are
waiting. Click the tray icon, or press the configured global keyboard
shortcut (`CommandOrControl+Shift+S` by default), to open or hide the
compact inbox popover. The shortcut can be changed or cleared from
Preferences. The popover shows implemented and failed Jobs, refreshes
every 30 seconds, syncs the unread notification count, and lets you open
the Job in Syrus or open its pull request in your browser when one
exists. Its header bell opens an in-popover notifications page with unread
badges, mark-read actions, Job navigation, and pull request links.
Selecting a row opens an in-popover Job detail view with back navigation,
the generated test plan, a copyable
`syrus checkout JOB-<id>` command, and the same browser, pull request,
approval, retry, and checkout actions as the inbox row. Implemented rows
can be approved for landing from the popover after a native confirmation
prompt, and implemented or failed Jobs can send follow-up feedback from
the detail view. Failed rows can be queued for retry directly from the row.
Local checkout actions require the `syrus` CLI binary on `PATH`; when the
app cannot find it, the popover shows an install banner and disables
checkout buttons. Configure a local projects root in Preferences to
derive `<root>/<repo-name>` paths, or add per-repository absolute path
overrides for repositories that live elsewhere. Desktop delegates
checkout to `syrus checkout JOB-<id>` from the resolved local path, so the
CLI handles branch fetching, dirty working trees, backup branches, and
repository-origin validation. After a successful checkout, the popover
automatically navigates to that Job's detail view so the test plan is
visible immediately. Admin users also see subtle footer toggles for
pausing or resuming repository polling and new Run starts, with
confirmation before either switch changes. Right-click the tray icon to
open the connected Syrus instance in your browser, open Preferences, or
quit the app.

Most commands accept a normal user API token and scope themselves to
what that user can see. Commands that read admin-only payloads, such as
top-level `syrus test-plan`, require an admin token.

## Repository Detection

When a command runs inside a GitHub checkout, Syrus reads the `origin`
remote and uses the detected `owner/name` repository. That keeps commands
like `syrus inbox`, `syrus job list`, `syrus job create`, `syrus epic
create`, and `syrus schedule create` focused on the repository in front
of you.

Outside a checkout, list commands fall back to all repositories visible
to the configured user. Creation commands that need a repository require
`--repo owner/name`.

## Chat

Run `syrus` with no subcommand to pick from recent chat sessions or start
a new session:

```bash
syrus
```

The terminal picker groups sessions for the current checkout first. The
REPL uses a compact `>` prompt, loads recent history, streams the
assistant response, and shows a single Latin busy phrase for the whole
turn. Ctrl+C stops the active turn; Ctrl+D exits.

Pass `--debug` when you need raw stream diagnostics such as MCP sidecar
events and provider result events:

```bash
syrus --debug
```

You can also send one message to an existing chat session:

```bash
syrus chat 123 "Inspect the queued proposals"
```

When a chat turn proposes a Job or Epic, the CLI pauses and asks whether
to confirm or skip the proposal before returning to the prompt.

## Inbox

`syrus inbox` opens an interactive review queue for implemented Jobs
awaiting approval and failed Jobs awaiting retry:

```bash
syrus inbox
syrus inbox --watch
syrus inbox --repo tkadauke/myapp
```

The inbox keeps a stable list while you work through it. New items appear
at the bottom, and items become read after you approve, retry, open a PR,
check out a branch, view a diff, or view a log.

Common keys:

| Key | Action |
| --- | --- |
| `j` / `down` | Move down |
| `k` / `up` | Move up |
| `a` | Approve an implemented Job |
| `r` | Retry a failed Job |
| `o` | Open the PR |
| `s` | Open the Job in Syrus |
| `c` | Check out the Job branch |
| `d` | View the diff in `$PAGER` |
| `l` | View the log in `$PAGER` |
| `R` | Refresh |
| `?` | Toggle help |
| `q` | Quit |

With `--watch`, an empty inbox stays open and refreshes every 30 seconds.

## Jobs

Use `syrus job` commands for direct Job work:

```bash
syrus job list --state open --limit 20
syrus job search "dark mode"
syrus job show 456
syrus job log 456
syrus job watch 456
syrus job diff 456
syrus job create
syrus job approve 456
syrus job cancel 456
syrus job retry 456
syrus job rebase 456
syrus job checkout 456
syrus job test-plan 456
syrus job open 456
```

`job create` prompts for a title and multi-line description, defaults to
the current checkout repository, and accepts `--repo owner/name` and
`--yes`.

`job log` pages completed transcripts through `$PAGER` and streams
running transcripts until the Job finishes or the command is interrupted.
`job diff` fetches the pull request diff through Syrus' GitHub
credential; if no GitHub token is available, it prints the PR URL.

`job checkout` verifies that the current checkout matches the Job's
repository, fetches the Syrus branch from `origin`, and checks it out. If the
remote Syrus branch was force-pushed, checkout refreshes the local branch to the
new remote head; when that branch is already checked out, local changes must be
committed or stashed first. After a successful checkout, the CLI runs any
`.syrus.yml` `hooks.post_checkout` commands from the repository root and
stops if one fails. Pass `--no-hooks` to skip those commands for one
checkout.

## Test Plans

The top-level test-plan shortcut accepts `JOB-123` slugs:

```bash
syrus test-plan JOB-456
```

When you are already on a Syrus Job branch, the argument is optional:

```bash
syrus test-plan
```

It infers the Job from branches like `syrus/issue-42-456`,
`syrus/direct-456`, `syrus/scheduled-10-456`, and `syrus/local-456`.
The command prints the newest completed workflow's `test_plan` artifact
as a numbered checklist.

After reviewing and testing locally, approve from the terminal:

```bash
syrus approve JOB-456
```

On success, Syrus queues the landing workflow.

## Epics

Use `syrus epic` to inspect and create Epics:

```bash
syrus epic list
syrus epic search "launch"
syrus epic show 12
syrus epic create
syrus epic open 12
```

`epic create` must run inside a GitHub checkout. It prompts for a title
and multi-line description, confirms the repository, creates the Epic,
and prints the Epic URL. Use `--yes` to skip the confirmation prompt.

## Repositories and Identity

These commands show the configured account and visible repositories:

```bash
syrus whoami
syrus repo list
syrus status
syrus status --repo acme/widgets
syrus status --closed
```

`status` lists active Jobs across repositories by default and can scope
to one repository.

## Schedules

Schedule commands use the app scheduled-task API:

```bash
syrus schedule list
syrus schedule create
syrus schedule show 42
syrus schedule delete 42
syrus schedule run 42
```

`schedule list` scopes to the current checkout when possible and
otherwise shows all schedules. `schedule create` must run from a
configured repository checkout because scheduled tasks are
repository-owned.

## Troubleshooting

If credentials are missing or incomplete, the CLI prints:

```text
Run 'syrus login' to set up your Syrus instance URL and API token.
```

If a repository-scoped command cannot detect a checkout, run it from a
GitHub repository or pass `--repo owner/name` when the command supports
it. If `checkout` refuses to run, compare the current `origin` remote
with the Job's repository; Syrus deliberately avoids checking out a
branch into the wrong repository.
