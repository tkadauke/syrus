---
title: Configuration
description: .syrus.yml, per-user settings, per-repo settings.
---

# Configuration

Syrus is configured in three layers:

| Layer | Lives in | Controls |
| --- | --- | --- |
| Deployment | Environment variables and Rails credentials | Database access, encryption keys, worker storage, queue sizing |
| User | The credentials/settings UI | GitHub token, agent credentials, preferred provider, max agent turns |
| Repository | Repository settings plus optional `.syrus.yml` in the target repo | Trigger label, polling, default branch, provider override, prepare commands |

For deployment-specific placement, see [Deployment](/docs/deployment).

## `.syrus.yml`

`.syrus.yml` is read from the root of the target repository during the
`prepare` Step. It currently configures deterministic setup commands that
run before the agent is invoked.

```yaml
prepare:
  - bundle install
  - npm ci
```

Schema:

| Key | Type | Meaning |
| --- | --- | --- |
| `prepare` | Array of strings | Shell commands to run in order before agent work starts |
| `prepare` | `[]` | Explicitly run no preparation commands |
| `prepare` | `false` | Opt out of preparation entirely |

Commands run from the workspace root under `bash -c`, so quoting, pipes,
and `&&` work. Each command has a 10 minute timeout. The environment is
scrubbed to a small safe allowlist so the Syrus worker's own Bundler,
Rails, or production environment settings do not leak into the target
repo's install.

If `.syrus.yml` is missing, Syrus auto-detects one setup command from the
first matching file:

| Signal | Command |
| --- | --- |
| `Gemfile` | `bundle install` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `package-lock.json` | `npm ci` |
| `package.json` | `npm install` |

Only the first match is used. A Rails app with both `Gemfile` and
`package-lock.json`, for example, gets `bundle install` unless it provides
an explicit `.syrus.yml`.

## Worked Examples

Syrus's own repo uses `.syrus.yml` to pin Bundler output into the cloned
workspace before installing gems:

```yaml
prepare:
  - bundle config set --local path vendor/bundle
  - bundle install --jobs 4
```

A Node repo that needs generated client code before the agent starts:

```yaml
prepare:
  - npm ci
  - npm run generate
```

A repo with no useful setup step:

```yaml
prepare: []
```

Or, equivalently:

```yaml
prepare: false
```

## Per-User Settings

Each user owns their own credentials and agent preferences.

| Setting | Purpose |
| --- | --- |
| GitHub token | Used to list issues, read PRs, push branches, open PRs, and post updates for that user's repositories |
| Agent provider | Default provider for new Jobs: `claude` or `codex` |
| Claude credential | Encrypted long-lived Claude OAuth token from `claude setup-token`, passed to Claude Code as `CLAUDE_CODE_OAUTH_TOKEN` |
| Codex credential | Encrypted Codex API key or ChatGPT login auth JSON, depending on auth mode |
| Agent max turns | Per-run cap for Claude Code tool-use turns; `0` means no `--max-turns` flag |
| Scheduling paused | Skips scheduled task firing for that user |
| Admin API token | Admin-only bearer token for `/api/v1/admin/*` diagnostics, including Jobs, Runs, queue/processes, and chat transcripts; shown once on rotation |

The credentials page includes a per-credential **Test** action after a
secret is saved. GitHub PAT tests call GitHub as the user and report the
authenticated login plus token scopes. Claude and Codex tests run short CLI
auth probes through the same credential paths used by Jobs, so expired or
mis-shaped agent credentials surface before a downstream run fails.

For Claude Code, generate the token with `claude setup-token` on a
machine with a browser, then paste the long-lived token it prints into
the credentials form. Do not copy the short-lived token from Claude
Code's local credential store; Syrus does not run Claude Code's local
refresh machinery. See Anthropic's
[long-lived token documentation](https://code.claude.com/docs/en/authentication#generate-a-long-lived-token).

Provider selection resolves from most specific to least specific:

```text
Workflow override -> Job provider -> Repository override -> User default
```

Budget thresholds are on the
[roadmap](https://github.com/tkadauke/syrus/blob/main/ROADMAP.md#claude-usage-budgets-and-thresholds).
Syrus already records per-run cost and token metadata where the provider
reports it, and the planned model is per-user and per-repo dollar caps over
rolling windows. Until that ships, use provider-side limits and the
per-user max-turns setting as the active safety rails.

## Per-Repository Settings

Repository settings are stored in Syrus, not in `.syrus.yml`.

| Setting | Default | Purpose |
| --- | --- | --- |
| Owner/name | None | GitHub repository to poll |
| Default branch | `main` | Base branch for clones, diffs, PRs, and rebases |
| Trigger label | `syrus` | Label that turns an issue into a Job |
| Polling enabled | `true` | If disabled, scheduled pollers skip the repo |
| Agent provider override | Blank | If set, new Jobs for the repo use this provider instead of the user's default |
| PR cost footer | `true` | Adds or updates a cost footer on PRs when cost data exists |
| Default issue workflow | `initial` | Label-triggered issues currently use the built-in Initial template |

The default workflow is not a free-form per-repo template yet. In the
current implementation, issue ingestion always starts the `initial`
workflow; scheduled tasks, PR feedback, CI failures, rebases, retries, and
manual actions choose their own trigger-specific templates.

## Worker Environment

The web and worker processes share the Rails environment. The worker also
needs durable workspace storage because it manages clones and worktrees.

| Variable | Required | Used by |
| --- | --- | --- |
| `RAILS_MASTER_KEY` | Production yes unless encryption keys are supplied directly | Decrypts Rails credentials |
| `SECRET_KEY_BASE` | Production yes | Rails sessions, signed cookies, message verification |
| `ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY` | Production yes unless stored in Rails credentials | Active Record encrypted credential columns |
| `ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY` | Production yes unless stored in Rails credentials | Deterministic Active Record encrypted columns, including admin API tokens |
| `ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT` | Production yes unless stored in Rails credentials | Active Record Encryption key derivation salt |
| `DB_HOST` | Production yes | MySQL host; defaults to `127.0.0.1` |
| `SYRUS_DATABASE_PASSWORD` | Production yes | MySQL password |
| `SYRUS_DATA_ROOT` | Worker recommended | Clone cache and per-workflow workspaces; defaults to `~/.syrus` |
| `SYRUS_GITHUB_REPO` | Yes | GitHub `owner/repo` slug for this Syrus installation's own repository; used for build revision links |
| `SYRUS_BUG_REPORT_OWNER` | Yes | GitHub owner or organization for in-app bug reports; Syrus uses the configured `syrus` repository under that owner |
| `JOB_CONCURRENCY` | No | Solid Queue worker thread count for the `runs` queue; defaults to `3` |
| `RAILS_MAX_THREADS` | No | Rails and database pool sizing |
| `RAILS_LOG_LEVEL` | No | Production log level; defaults to `info` |
| `PORT` | Web only | Rails server port; defaults to `3000` |
| `GIT_SHA` | No | Displayed build revision |

`SYRUS_DATA_ROOT` should point at a persistent volume for worker pods.
Web pods do not need clone storage. The mounted directory must be writable
by the container's `rails` user (`1000:1000`); the published Docker images
create `/home/rails/.syrus` with that ownership so a fresh named volume can
inherit it on first mount.

## Secret Management

Per-user credentials use Active Record Encryption:

- `github_token`
- `claude_oauth_token`
- `codex_api_key`
- `codex_auth_json`
- `api_token`

The encrypted values live in the primary database. In production, provide
the three `ACTIVE_RECORD_ENCRYPTION_*` values directly through the
environment, or store them in Rails credentials and provide
`RAILS_MASTER_KEY`. Any process that reads or writes users needs the same
stable encryption-key source. This is why smoke tests or console sessions
that create users fail loudly when the keys are missing.

GitHub push tokens are not written into clone remotes. Syrus keeps clone
remotes anonymous and constructs a token-bearing push URL only for the
individual `git push` call.

For token rotation, users update their GitHub and agent credentials in the
credentials UI by submitting a replacement value. Admin API tokens are
rotated separately and displayed only once; admins can also revoke the token
from the same credentials page, which immediately removes API access until a
new token is generated. For Rails encryption key rotation, follow Rails
Active Record Encryption rotation practice: deploy the new scheme while
retaining read access to old ciphertext, rewrite encrypted attributes, then
remove the old scheme after verification.
