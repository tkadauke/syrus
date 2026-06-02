# Syrus

> *Bis dat qui cito dat.*
> He gives twice who gives quickly. — Publilius Syrus

A multi-user, cross-repo issue→PR automation harness. Syrus owns the
deterministic plumbing — clones, branches, PRs, cleanup, retries, scheduled
tasks, and rebases — so coding agents can focus on writing code.

## What problem this solves

Today the issue→PR loop runs manually per repo. Claude spends a meaningful
fraction of its context on `git worktree add`, branch naming, push retries,
and PR-creation boilerplate. When that mechanics layer goes off the rails
(stale worktrees, dirty trees, wrong base branch) the whole job dies.

**Syrus owns the mechanics. The agent only writes code.**

## MVP Surface

| Choice | Decision |
| --- | --- |
| Stack | Rails 8 + Solid Queue (MySQL in prod, SQLite in dev/test) |
| Trigger model | External polling for GitHub issues, PR feedback, CI failures, merge state, and scheduled tasks |
| Auth | Multi-user, first signup = admin, then invite-only |
| Credentials | Per-user, encrypted at rest (GitHub token, Claude credential, Codex credential, admin API token) |
| Workers | Separate container from the web app |
| Deploy target | Kubernetes or Docker Compose; see `website/src/content/docs/deployment/` |
| Domain | Configurable via `SYRUS_APP_HOST` |

Syrus ships these MVP workflows:

- Labeled GitHub issue → prepare → implement → summarize → open PR.
- PR feedback or failing checks → prepare → agent follow-up → summarize
  amendment → push to the same PR.
- Unmergeable controlled PR branch → deterministic rebase first, then an
  agent rebase only if conflicts need judgment, followed by
  `git push --force-with-lease` against the branch SHA Syrus observed.
- Scheduled cron or one-shot task → normal issue-to-PR pipeline with
  pile-up policy (`skip`, `pile`, or `replace`).
- Direct operator-created Job → normal issue-to-PR pipeline without a
  GitHub issue.

The MVP deliberately does **not** include inbound GitHub delivery, hosted
multi-tenant sandboxing, out-of-band human escalation, shared drawing
surfaces, native GitHub suggestion application, or captured-session
continuation.

## Security Posture

The MVP assumes trusted users operating on trusted repositories. Agent runs
execute in worker-managed per-Workflow workspaces under `SYRUS_DATA_ROOT`, not
inside a hardened untrusted-code sandbox. This protects the operator checkout
from accidental agent `chdir` mistakes, but it is not a security boundary.

Run Syrus on infrastructure you control, register repositories whose code and
setup commands you are willing to execute, scope GitHub tokens narrowly, keep
secrets out of repositories, and review generated PRs before merging.

## Getting started

Requires Ruby 3.2.3 (see `.ruby-version`). MySQL is **not** needed for local dev.

```sh
bin/setup    # bundle, db:prepare, log:clear; tails into bin/dev
bin/dev      # foreman: web (rails s) + worker (bin/jobs) + css (tailwind:watch)
bin/test     # run Ruby, legacy JS, and React/TypeScript tests
```

`bin/setup --skip-server` if you want to bootstrap without booting the dev server.

## Production Configuration

Production configuration is driven by environment variables so each deployment
can provide the hostnames and mail settings appropriate to its environment:

- `SYRUS_APP_HOST` — optional public app host used for URL generation and mailer links.
- `SYRUS_ALLOWED_HOSTS` — optional comma-separated host allowlist. Defaults to `SYRUS_APP_HOST`.
- `SYRUS_ASSUME_SSL` / `SYRUS_FORCE_SSL` — optional booleans, both default `true` for TLS-terminating ingress/proxy deployments. `/up` is excluded from SSL redirects and host authorization for health checks.
- `SYRUS_MAILER_FROM` — optional sender address for application mail. Defaults to `Syrus <noreply@SYRUS_APP_HOST>`.
- `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_AUTHENTICATION`, `SMTP_ENABLE_STARTTLS_AUTO` — optional SMTP settings. When `SMTP_ADDRESS` is absent, Rails keeps its default mail delivery configuration and delivery errors are not raised unless `SYRUS_MAILER_RAISE_DELIVERY_ERRORS=true`.

## Per-Issue Controls

Syrus recognizes `syrus-skip-prepare` on a source issue as an escape hatch for
broken prepare commands. Jobs ingested with that label skip the prepare step and
start at implementation; removing the label restores the normal prepare-first
workflow on the next ingest.

## Scheduled Tasks

Cron tasks use five-field cron expressions in UTC, but the MVP treats them
as hourly windows: the minute field is ignored for schedule matching, and a
task fires at most once in a matching UTC hour. Syrus stores a per-task
minute offset so many tasks with the same nominal schedule do not all fire on
the same poll tick.

## Credential Controls

Users can replace GitHub and agent credentials from **My credentials** by
submitting a new value. Admin API tokens are controlled separately: admins can
generate, rotate, or revoke them from the same page. Rotating invalidates the
old token immediately; revoking removes API access until a new token is
generated.

## Naming

Named after [Publilius Syrus](https://en.wikipedia.org/wiki/Publilius_Syrus),
the 1st-century-BCE Roman writer whose *Sententiae* — a collection of
one-line maxims — were schoolbook material for over a millennium and seeded
a surprising number of phrases still in everyday use. He was a writer, same
job the LLM is doing inside this harness, and his output outlived him by
two thousand years. That's the aspiration: small, durable text that
compounds. Thomas first encountered him in high-school Latin readings.
