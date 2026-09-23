# Git Mirror

Git Mirror keeps a bare mirror of every active git repository and answers
Syrus's repository reads from it -- the `.syrus.yml` read before each workflow
is built, preview project discovery, skills, the Job source browser, and
`CommitsBehindCalculator`'s numeric `divergence` (ahead/behind commit counts)
for merge-state polling's `commits_behind_base` -- before the hosting
platform's API is asked. It also serves the clones and fetches that populate
workflow and chat workspaces: a plain `git clone`/`git fetch` speaks its
smart-HTTP git transport directly, read-only. Together this takes most of
Syrus's reads, and the biggest single source of traffic (a full clone per
Workflow), off GitHub's rate limit and out of a network round trip, at the
cost of disk space for the mirrors. Off by default.

It is a `:replica` `repository_content_provider` (see `plugins.md`) for file,
tree, diff, commit history, and commit tree SHA reads: whenever it cannot
answer -- the service is down, a commit has not reached it, a request it does
not support -- the read falls through to the host, exactly as if the plugin
were disabled. It is also a `workspace_git_transport` provider (same
extension point contract, a different consumer): `WorkflowWorkspace` and
`ChatWorkspace` try it first for every clone/fetch and fall back to the host
on any failure.

## Requirements

- **Plugin Runtime**, which Git Mirror depends on, to run or locate the
  service.
- An upstream content provider that can say where each repository lives and
  hand over a credential (`upstream_source`) -- GitHub Host for GitHub
  repositories. A repository no upstream can feed is not served by the mirror.

## Running the service

**Docker Compose.** Enable Plugin Runtime and Git Mirror. The runtime manager
pulls `ghcr.io/tkadauke/syrus-plugin-git-mirror` at the tag matching your
Syrus release, starts it with a `data` volume, and hands it its token. Nothing
to configure.

**Kubernetes.** Deploy the image yourself with a persistent volume at `/data`
and set, on both the mirror and the Syrus web and worker pods:

| Variable | Where | Value |
| --- | --- | --- |
| `GIT_MIRROR_TOKEN` | mirror | a random string of 32+ characters |
| `SYRUS_GIT_MIRROR_TOKEN` | Syrus | the same string |
| `SYRUS_PLUGIN_SERVICE_GIT_MIRROR_URL` | Syrus | e.g. `http://git-mirror:8080` |

The mirror needs outbound HTTPS to your git host; it needs no route to Syrus.
If you deploy with `bin/deploy`, any workload running
`ghcr.io/tkadauke/syrus-plugin-git-mirror` is pinned to the deploy's SHA along
with Syrus itself, so the mirror and Syrus stay on the same commit.

Optional on the mirror: `GIT_MIRROR_SYNC_INTERVAL` (default `30s`) and
`GIT_MIRROR_FETCH_TIMEOUT` (default `10m`). On Syrus, `SYRUS_GIT_MIRROR_IMAGE`
overrides the image Compose runs.

## How it stays in sync

Once a minute, Syrus registers every active git repository with the mirror:
its HTTPS fetch URL and a short-lived credential (for GitHub, the App
installation token or the owner's PAT). The mirror keeps credentials in memory
only -- never on disk, never on a command line -- and fetches every repository
in the background every 30 seconds. Mirrors of repositories Syrus no longer
works on are removed; a repository whose registration merely failed is kept.

Reads are keyed by commit, and a commit's contents never change, so the mirror
answers exactly what the host would for any commit it has. A commit it has not
seen yet is fetched once on demand. Resolving a branch honours the caller's
`max_age` (60 seconds by default): an older view is refreshed first, and if
the host cannot be reached the mirror says so rather than returning a stale
commit, so the read falls back to the host.

## Clones and fetches

`WorkflowWorkspace`'s initial clone and `ChatWorkspace`'s repository
attachment try the mirror's smart-HTTP routes
(`<endpoint>/v1/repositories/<id>`, the same `git clone`/`git fetch` a real
git remote answers) before the host, authenticated with the same bearer token
as the JSON API via an `http.extraHeader` -- never embedded in the URL, so it
never lands in `.git/config` or a logged git error. A repository the mirror
has not been told about since it last restarted registers on the spot and
retries once, the same recovery the content reads use.

A branch tip the mirror hasn't caught up to yet is an accepted staleness
window, same as any `max_age`-bounded read; but two cases are verified
explicitly, because silently landing on a stale commit there would be worse
than falling back: refreshing a Job's already-existing branch checks the
fetched commit against the exact SHA a `ls-remote` against the host just
reported, and checking out a Syrus-pinned commit (`main_sha`, `deploy_sha`,
a landed merge commit) fetches that exact commit from the host if the mirror
didn't have it. Either check failing falls back to the host for that
operation, transparently.

Only `refs/heads/*` and `refs/tags/*` are mirrored, so operations against
other refs -- a GitHub pull request's `refs/pull/<n>/head`, a Syrus run
checkpoint's `refs/syrus/checkpoints/...` -- always go straight to the host;
the mirror is never asked for them. The mirror never accepts a push: its
smart-HTTP routes only implement `git-upload-pack` (fetch/clone), and there
is no `git-receive-pack` route at all for a client to reach.

## Checking that it works

After enabling, expect about two minutes before the mirror serves anything:
one Plugin Runtime tick to see the service healthy, then one Git Mirror tick
to register repositories.

- **Who answered:** `syrus_repository_content_reads_total` on `/metrics`
  counts reads by provider. Mirror hits show as `provider="git_mirror",
  outcome="answered"`; fall-backs as a `git_mirror` fall-through outcome
  followed by `provider="github"`. See `metrics.md`.
- **What the mirror did:** the service logs one line per request, e.g.
  `GET /v1/repositories/7/blob?revision=…&path=README 200 13B 2ms`, and every
  fetch failure. Health checks and credentials are never logged.
  (`docker logs syrus-plugin-git-mirror` on Compose.)
- **What is mirrored, and how big:** Admin -> Plugin Services -> Details on
  `git-mirror` shows the repository count, the mirrors' size, the volume's free
  and total space, and each repository's size, last fetch, last gc, and last
  error. The same numbers are gauges: `syrus_git_mirror_repositories`,
  `syrus_git_mirror_mirror_bytes`, `syrus_git_mirror_disk_free_bytes`, and
  `syrus_git_mirror_disk_total_bytes` (alert on free space).
- **Housekeeping:** after a successful fetch, a repository gets
  `git gc --auto` at most once a day, which does nothing until loose objects
  or packs pile up. Branches deleted upstream are pruned on every fetch.

## Limits

- Serves git only. Mercurial and Subversion mirrors would be separate plugins.
- Diffs come with per-file line counts and, when asked, hunks. Binary files
  have neither, and a single file's patch over 256 KiB is omitted, as GitHub
  does.
- After the service restarts it serves everything on its volume but holds no
  credentials. It does not fetch repositories Syrus has not re-registered
  (so a private repository does not fail every background sync), and a read
  that needs a fetch answers `unregistered`; Syrus then registers that
  repository on the spot and retries, so the first such read heals it rather
  than waiting for the next tick.

## Disabling

Disabling removes the service (on Compose) and every read goes to the host
again. The mirrors' volume is kept, so re-enabling does not re-clone
everything. To reclaim the space, delete it under Admin -> Plugin Services ->
Stored data, or run `bin/rails 'plugin:purge[git_mirror]'` after uninstalling
the plugin.
