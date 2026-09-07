---
title: Syrus CLI
description: Install, authenticate, chat, review, and manage Syrus work from the terminal.
---

# Syrus CLI

The Syrus CLI is a standalone Go binary under `cli/`. It talks to the
same app and admin JSON APIs as the React UI, but keeps the common
operator loop close to the checkout: chat with Syrus, review inbox items,
open PRs, check out Job branches, and print test plans.

## Installed with the desktop app

If you run the [Syrus desktop app](/docs/desktop), you don't need a
repository clone or Go: the app installs the bundled CLI automatically
when it starts, and re-installs it whenever an app update ships a newer
binary — no step to remember, nothing to keep current. Because the app
already stores its credentials in the CLI's shared `~/.syrus/credentials`
file, the CLI is signed in immediately — no `syrus login` needed. This
also powers the tray's **Checkout** button, which runs `syrus checkout`
under the hood.

If Claude Code or Codex is set up on the machine, the app additionally
offers (once) to add the [Claude Code skill](#claude-code-skill) so agent
sessions can drive Syrus through the CLI; the skill is also available any
time from **Preferences → Local checkout → Add Claude Code skill**. A
**Reinstall CLI** button lives in the same place for the rare case the
automatic install failed.

- **macOS** installs to `~/.local/bin/syrus`; if that isn't on your
  `PATH`, the app shows the one-line export to add.
- **Windows** installs to `%LocalAppData%\Syrus\bin\syrus.exe` and adds
  that directory to your user `PATH` automatically — open a **new**
  terminal to pick it up.

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

When credentials already exist (for example, the desktop app wrote
them), `syrus login` prefills the saved URL and offers to keep the
current token — refreshing a stale token is just Enter, then paste the
new token. For scripting, `--url` and `--token` skip the prompts:

```bash
syrus login --url https://syrus.example.com --token your-api-token
```

If any command answers `401 Unauthorized`, the saved token is stale
(most commonly the instance's database was rebuilt); the error suggests
`syrus login`, and the desktop app heals its own copy automatically the
next time its window is open and signed in.

Syrus Desktop reads and writes the same credentials file. If you have
already run `syrus login`, the desktop app starts authenticated. If the
file is missing or incomplete, the desktop app prompts for the same URL
and API token, validates them against `/api/v1/app/bootstrap`, and saves
the file for both desktop and CLI use. While signed in, the desktop main
process keeps a live connection to the user's app events so native
notifications, tray badge state, and renderer views can react without
opening separate WebSocket connections. `notification_created` events show
OS-level banners using the notification body from Syrus; clicking a banner
opens the matching Job page or pull request in the browser. Users can turn
desktop banners for implemented and failed Jobs on or off from account
preferences in the web UI. The desktop inbox also watches its polled Job
list for in-session transitions to implemented or failed and shows a
native banner for those changes; clicking that banner focuses the tray
popover on the matching Job.

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
tabs for the generated summary, test plan, and submitted feedback. The test
plan tab includes a copyable `syrus checkout JOB-<id>` command, and the
same browser, pull request, approval, retry, and checkout actions as the
inbox row stay visible below the tabs. Implemented rows
can be approved for landing from the popover after a native confirmation
prompt, and implemented or failed Jobs can send follow-up feedback from
the detail view. Failed rows can be queued for retry directly from the row.
Local checkout actions require the `syrus` CLI (the app finds a
`~/.local/bin/syrus` install even though GUI apps get a minimal `PATH`);
when it's missing, the popover shows a banner with a one-click Install
button and disables checkout buttons until it lands. Configure a local projects root in Preferences to
derive `<root>/<repo-name>` paths, or add per-repository absolute path
overrides for repositories that live elsewhere. Desktop delegates
checkout to `syrus checkout JOB-<id>` from the resolved local path, so the
CLI handles branch fetching, dirty working trees, backup branches, and
repository-origin validation. When the popover opens, Desktop runs
`syrus status --json` from the last checked-out or configured local
checkout path. If that checkout is on a Syrus Job branch, the matching
inbox row gets a local badge; branches behind remote show an amber
warning, and hidden or filtered Jobs appear as a compact "Checked out"
status line. After a successful checkout, the popover automatically
navigates to that Job's detail view so the test plan is visible
immediately. Admin users also see subtle footer toggles for pausing or
resuming repository polling and new Run starts, with
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

The terminal picker groups sessions for the current checkout first. On a
real terminal, the chat itself opens as a full-screen frame with three
regions: a scrollable history pane, a multi-line input area, and a thin
status line showing the chat title/repository and a busy indicator (a
single Latin phrase) while a turn is streaming. Tool calls the agent makes
during a turn render live in the history pane as a compact `› toolname`
line, followed by a one-line result summary — the same format used when
replaying a session's history.

- **Enter** sends the message; **Ctrl+J** inserts a literal newline for a
  multi-line message instead of sending.
- **Up/Down** at the first or last line of the input recalls previously
  sent messages from this session (an in-memory list, not saved across
  sessions); otherwise the arrow keys move the cursor between lines as
  usual.
- **PgUp/PgDn** or the mouse wheel scroll the history pane.
- **Ctrl+C** interrupts the in-flight turn; press it again once idle to
  exit.

When stdin/stdout aren't a real terminal (piped input, scripted use),
Syrus falls back to a plain line-based prompt instead: a compact `>`
prompt, no alt-screen frame, and Ctrl+D to exit.

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
to confirm (`c`) or skip (`s`) the proposal before returning to the input.

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
syrus job list --repo tkadauke/myapp
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

Commands that accept a Job ID also accept `JOB-<n>` (e.g. `JOB-456`) and
human-readable slugs derived from the job title (e.g.
`syrus job show repair-aqueduct`). The same applies to `syrus checkout`,
`syrus test-plan`, and `syrus approve`.

`job create` prompts for a title and multi-line description, defaults to
the current checkout repository, and accepts `--repo owner/name` and
`--yes`. Optional flags set fields the API already accepts but that the
interactive prompt does not ask for: `--priority` (`urgent`, `high`,
`medium`, or `low`; omitted defaults to `medium` server-side), `--agent`
(an agent provider slug, e.g. `claude` or `codex`), `--epic` (an Epic to
attach the job to, as `EPIC-<id>` or a slug — resolved to its numeric ID
before the job is created), and `--owner` (the numeric user ID of a
repository member to assign as owner). All four are optional and omitted
entirely from the request when not passed, rather than sent as blank
values.

`job log` pages completed transcripts through `$PAGER` and streams
running transcripts until the Job finishes or the command is interrupted.
`job diff` fetches the pull request diff through Syrus' GitHub
credential; if no GitHub token is available, it prints the PR URL.

`job show`, `job list`/`job search`, `job log`, `job watch`, and `job diff`
all accept `--json`, matching `syrus status --json`: instead of the
human-readable rendering, they print the already-fetched API response as
JSON on stdout for scripting and the desktop app. `--json` disables the
polling behavior of `job log` and `job watch` — each prints a single
snapshot of the current transcript or Job state and exits rather than
following it.

`job list`/`job search` also accept `--repo owner/name` to scope results to
one repository, overriding auto-detection from the current checkout; without
it they fall back to the detected repository (or all repositories visible to
the user, outside a checkout), same as `syrus jobs` and `syrus inbox`.

`job checkout` verifies that the current checkout matches the Job's
repository, fetches the Syrus branch from `origin`, and checks it out. If the
remote Syrus branch was force-pushed, checkout refreshes the local branch to the
new remote head; when that branch is already checked out, local changes must be
committed or stashed first. After a successful checkout, the CLI runs any
`.syrus.yml` `hooks.post_checkout` commands from the repository root and
stops if one fails. Pass `--no-hooks` to skip those commands for one
checkout.

If `<arg>` doesn't resolve to a Job or Epic (the API responds 404), `syrus
checkout` falls back to treating it as a plain git branch name — e.g. `syrus
checkout main` or `syrus checkout a-teammates-feature-branch`. This fallback
is a plain fetch + checkout with no repository-slug matching (there's no Job
to compare against) and none of the force-reset/backup-branch behavior a Job
branch checkout uses (that machinery exists only because Syrus force-pushes
agent commits onto Job branches). It fails with a clear error instead of
silently discarding work if local changes would be overwritten or the local
branch has diverged from `origin`, and it fails with a "not found" error if
the branch doesn't exist locally or on `origin`. It still runs
`.syrus.yml` `hooks.post_checkout` commands afterward (respecting
`--no-hooks`), but has no Job to report a test-plan hint for. A non-404 API
error (e.g. a network failure or server error) is surfaced as-is and does not
trigger the branch fallback.

`syrus checkout EPIC-N --complete` (where `N` is a numeric ID or a
human-readable slug such as `EPIC-add-auth-system`) automatically selects the single branch
that contains all of the Epic's implemented changes and checks it out, without
opening the interactive picker. It uses a two-step algorithm:

1. If the Epic has an active merge-train integration branch (set by
   `merge_train_build` and not yet landed), that branch is checked out
   directly — it is, by construction, a descendant of all member branches.
2. Otherwise, Syrus fetches all implemented job branches and finds the one
   that is a git descendant of every other (i.e. the "tip" of a linear
   stack). If exactly one such branch exists it is checked out; if the
   branches are not linearly stacked the command fails with an error
   suggesting `syrus checkout EPIC-N` for manual selection.

`--complete` is useful after an Epic's Jobs have been reviewed and merged
in sequence, or when working with a stacked-branch workflow where one
branch is explicitly built on top of another.

## Test Plans

The top-level test-plan shortcut accepts a numeric ID, a `JOB-<n>` slug,
or a human-readable slug derived from the job title:

```bash
syrus test-plan JOB-456
syrus test-plan repair-aqueduct
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

## Local Status

`syrus status` reports whether the current checkout is on a Syrus Job
branch and whether that branch is behind `origin`:

```bash
syrus status
syrus status --json
```

On a Job branch, it fetches the matching remote branch before counting
commits behind:

```text
JOB-1291 (syrus/direct-1291) — up to date
JOB-1291 (syrus/direct-1291) — ⚠ 2 commit(s) behind remote
```

The JSON form is intended for desktop and scripting integrations:

```json
{"job_id":1291,"branch":"syrus/direct-1291","behind":2}
```

When the current branch is not a Syrus Job branch, it prints `Not on a
Syrus job branch.` or returns `{"job_id":0,"branch":"","behind":0}` with
`--json`.

## Local Mode

`syrus local` pairs this machine to a Syrus chat session so the chat agent
can read and write files, run shell commands, and inspect git state
directly on your machine instead of a server-side clone:

```bash
syrus local --chat 123 --token abc123...
```

It requires the `local_mode` Labs feature flag to be enabled on your Syrus
instance and a chat session already switched to Local mode. Pairing starts
from the chat UI, not the CLI: while a chat is in Local mode and not yet
connected, Syrus shows a banner with the exact `syrus local --chat
<chat_session_id> --token <auth_token>` command to copy and run. Running it
opens a persistent reverse WebSocket tunnel from your checkout to the Syrus
backend and reconnects automatically (with backoff) if the connection
drops; press Ctrl+C to disconnect cleanly.

Flags:

| Flag | Description |
| --- | --- |
| `--chat` | Syrus chat session id from the pairing command (required) |
| `--token` | Pairing auth token from the pairing command (required) |
| `--dir` | Path to the git repository (defaults to the current directory) |

The command must run inside a git repository (or point `--dir` at one); it
derives the repository slug from the `origin` remote and reports the
current branch when it connects. Local Mode intentionally bypasses graders,
the landing queue, and other Syrus automation, so treat the pairing token
as sensitive — it grants file and command access to this machine for the
lifetime of the paired chat session.

## Epics

Use `syrus epic` to inspect and create Epics:

```bash
syrus epic list
syrus epic list --repo tkadauke/myapp
syrus epic search "launch"
syrus epic show 12
syrus epic create
syrus epic open 12
```

`epic create` must run inside a GitHub checkout. It prompts for a title
and multi-line description, confirms the repository, creates the Epic,
and prints the Epic URL. Use `--yes` to skip the confirmation prompt.

`epic list`/`epic search` and `epic show` also accept `--json` for the
same JSON-on-stdout behavior as the Job commands above. `epic list`/`epic
search` also accept `--repo owner/name`, overriding auto-detection the same
way as `job list`/`job search`.

## Repositories and Identity

These commands show the configured account and visible repositories:

```bash
syrus whoami
syrus repo list
syrus jobs
syrus jobs --repo acme/widgets
syrus jobs --closed
```

`syrus whoami` and `syrus repo list` accept `--json` too.

`jobs` lists active Jobs across repositories by default and can scope
to one repository.

## Schedules

Schedule commands are contributed by the bundled `scheduled_tasks` plugin
rather than built into the CLI core, and use the app scheduled-task API:

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

## Kubernetes clusters

`syrus k8s` commands are contributed by the bundled `k8s_cluster` plugin
and browse clusters registered from Admin -> Kubernetes Clusters, using
the same admin API the web UI's cluster browser and the agent's
`k8s_cluster_*` chat/workflow tools call:

```bash
syrus k8s clusters
syrus k8s namespaces --cluster 1
syrus k8s pods --cluster 1 --namespace web
syrus k8s deployments --cluster 1
syrus k8s services --cluster 1
syrus k8s nodes --cluster 1
syrus k8s pvcs --cluster 1
syrus k8s events --cluster 1
syrus k8s logs web-abc123 --cluster 1 --namespace web --container app --tail 100
syrus k8s overview --cluster 1
```

`--cluster` is required whenever more than one cluster is registered;
with exactly one registered cluster it is inferred automatically. All
resource commands except `nodes` and `overview` accept `--namespace` to
restrict the listing; omitting it lists across every namespace, the same
as `kubectl get <kind> -A`. These commands require an admin API token,
same as `syrus test-plan`.

This command group is read-only. The plugin's cluster actions (deleting a
pod, restarting a rollout, scaling a deployment, cordoning a node) are
only exposed as MCP tools today, with no backing REST endpoint for the
CLI to call — the CLI does not duplicate them.

## Search

`syrus search` is contributed by the bundled `global_search` plugin and
calls the same unified search endpoint the app's search bar uses to rank
results across Jobs, Epics, and chats in one query:

```bash
syrus search "dark mode"
syrus search deploy --type job,chat
syrus search deploy --limit 10
syrus search deploy --json
```

`--type` restricts the search to a comma-separated list of `job`, `epic`,
and/or `chat`; omitting it searches all three. `--limit` caps the number
of results (server default: 30, capped at 100). Results print as a
compact one-line-per-result table grouped by type, in the order each
type first appears in the server's relevance ranking. `--json` prints
the raw API response instead, including the facet/filter payload the web
UI's search page uses.

A query under two characters is rejected by the server; the CLI surfaces
that error message as-is rather than duplicating the validation.

## Design Docs

`syrus docs` is contributed by the bundled `design_docs` plugin and reads
the same app API the web UI's Design Docs page and the chat
`read_design_doc`/`list_design_docs` MCP tools call:

```bash
syrus docs list
syrus docs list --repo acme/widgets
syrus docs show DOC-10
syrus docs show 10
```

`docs list` scopes to the current checkout when possible (or to
`--repo owner/name` when given) and otherwise lists every doc you can
see; an unrecognized `--repo` is an error, but a checkout-detected repo
that Syrus doesn't know about quietly falls back to the unscoped list.
`docs show` accepts either a `DOC-<id>` reference or a bare numeric id
and pages the doc's rendered body through `$PAGER`, the same as
`syrus job log`. This command group is read-only — proposing a doc,
commenting, or suggesting a change are chat/proposal-flow features with
no CLI equivalent. If the `design_docs` plugin is disabled, both
commands surface the API's `plugin_disabled` error message as-is.

## Spending insights

`syrus insights spending` is contributed by the bundled `spending_insights`
plugin and reads the same app API that backs the web UI's `/insights/spending`
page — cost rollups from `Run#cost_usd` and `ChatSession#cumulative_cost_usd`:

```bash
syrus insights spending
syrus insights spending --since 2026-06-01 --until 2026-06-30
syrus insights spending --group-by user
syrus insights spending --group-by epic
syrus insights spending --group-by trigger_kind
syrus insights spending --json
```

`--since`/`--until` take `YYYY-MM-DD` dates and are passed straight through
as the API's date window; omitting either lets the server apply its own
default (a 90-day trailing window). `--group-by` picks which breakdown table
prints below the headline totals: `repo` (default), `user`, `epic`, or
`trigger_kind` — the same breakdowns the web page's dashboard shows. There is
no `agent_provider` breakdown in the API response (only an `agent_provider`
*filter*, which this v1 command does not expose), so it is not a `--group-by`
option. `--json` prints the full raw API response instead of the summary,
including the top-runs and trend detail the text summary omits.

Access control is entirely server-side and this command does not try to work
around it: non-admins always see only their own spend, and admins see
instance-wide totals across every user — the command renders whichever scope
the API says it used.

## Claude Code skill

The CLI can teach Claude Code how to drive Syrus:

```bash
syrus skill install                       # writes ~/.claude/skills/syrus/SKILL.md
syrus skill install --dir /path/to/skills # custom skills directory
```

The skill describes the command surface (inbox, job view, test plans,
checkout, approve, chat) and its guardrails — approve only on explicit
user instruction, never check out over a dirty working tree, prefer
read commands when the user is reviewing. With it installed, a local
Claude Code session can triage your Syrus inbox, read a test plan,
check the branch out, and run it — all through the same CLI you use.
New agent sessions pick the skill up automatically; the desktop app's
CLI install step offers it as a checkbox.

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
