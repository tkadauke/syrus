# Git Mirror

Git Mirror keeps a bare mirror of every active git repository and answers
Syrus's repository reads from it -- the `.syrus.yml` read before each workflow
is built, preview project discovery, skills, the Job source browser -- before
the hosting platform's API is asked. It takes most of those reads off GitHub's
rate limit and out of a network round trip, at the cost of disk space for the
mirrors. Off by default.

It is a `:replica` `repository_content_provider` (see `plugins.md`): whenever
it cannot answer -- the service is down, a commit has not reached it, a
request it does not support -- the read falls through to the host, exactly as
if the plugin were disabled.

## Requirements

- **Plugin Runtime**, which Git Mirror depends on, to run or locate the
  service.
- An upstream content provider that can say where each repository lives and
  hand over a credential (`upstream_source`) -- GitHub Host for GitHub
  repositories. A repository no upstream can feed is not served by the mirror.

## Running the service

**Docker Compose.** Enable Plugin Runtime and Git Mirror. The runtime manager
pulls `ghcr.io/tkadauke/syrus-plugin-git-mirror` at the tag matching your
Syrus build, starts it with a `data` volume, and hands it its token. Nothing
to configure.

**Kubernetes.** Deploy the image yourself with a persistent volume at `/data`
and set, on both the mirror and the Syrus web and worker pods:

| Variable | Where | Value |
| --- | --- | --- |
| `GIT_MIRROR_TOKEN` | mirror | a random string of 32+ characters |
| `SYRUS_GIT_MIRROR_TOKEN` | Syrus | the same string |
| `SYRUS_PLUGIN_SERVICE_GIT_MIRROR_URL` | Syrus | e.g. `http://git-mirror:8080` |

The mirror needs outbound HTTPS to your git host; it needs no route to Syrus.

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

## Limits

- Serves git only. Mercurial and Subversion mirrors would be separate plugins.
- Does not serve diff patches; those come from the host.
- After the service restarts it serves everything on its volume but cannot
  fetch until the next tick sends credentials, at most a minute later.

## Disabling

Disabling removes the service (on Compose) and every read goes to the host
again. The mirrors' volume is kept, so re-enabling does not re-clone
everything; to reclaim the space, remove it by hand
(`docker volume rm <project>_plugin_git-mirror_data`, `syrus_plugin_git-mirror_data`
on a default install).
