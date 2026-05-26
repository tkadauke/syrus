# Syrus

> *Bis dat qui cito dat.*
> He gives twice who gives quickly. — Publilius Syrus

A multi-user, cross-repo issue→PR automation harness. Replaces the per-repo
`process-issues` / `process-prs` / `implement-issue` Claude skills with a
single Rails app that owns the deterministic plumbing — worktrees, branches,
PRs, cleanup — so Claude can focus on writing code.

## What problem this solves

Today the issue→PR loop runs manually per repo. Claude spends a meaningful
fraction of its context on `git worktree add`, branch naming, push retries,
and PR-creation boilerplate. When that mechanics layer goes off the rails
(stale worktrees, dirty trees, wrong base branch) the whole job dies.

**Syrus owns the mechanics. The agent only writes code.**

## Architecture (locked in)

| Choice | Decision |
| --- | --- |
| Stack | Rails 8 + Solid Queue (MySQL in prod, SQLite in dev/test) |
| Trigger model | Polling (no webhooks for v1 — keeps deploy boundary clean) |
| Auth | Multi-user, first signup = admin, then invite-only |
| Credentials | Per-user, encrypted at rest (Claude API key + GitHub token) |
| Workers | Separate container from the web app |
| Deploy target | K3s via `green_acres`, alongside Winston/Gloria |
| Domain | `agents.green-acres.estate`, overrideable via `SYRUS_APP_HOST` |

Inspiration: tiny_ci's lightweight self-host posture. Not a fork — fresh app.

## Roadmap

The make-or-break milestone is **M3** — once the deterministic harness opens
empty PRs reliably, swapping in the agent at M4 is mechanical.

| Milestone | Goal |
| --- | --- |
| **M0** | Rails 8 scaffold: SQLite (dev/test) + MySQL (prod), Solid Queue, Procfile, dev bootstrap |
| **M1** | Data model: User (first=admin), encrypted creds, RepositoryRegistry, Job state machine |
| **M2** | GitHub poller: per-user token, label-triggered issue ingestion, dedup |
| **M3** | Deterministic harness — clones, branches, opens an empty PR, cleans up. **No AI yet.** |
| **M4** | Agent invocation: replace the placeholder commit with `claude-code`, stream transcript |
| **M5** | Web UI: repo registry CRUD, job dashboard, live transcript, retry/cancel |
| **M6** | PR feedback loop: poll review comments, dispatch follow-up jobs |
| **M7** | Hardening: worker isolation, resource limits, k8s secrets, Prometheus metrics, retention |
| **M8** | Rollout: deploy to K3s, migrate first real repo, retire per-repo claude skills |

## Getting started

Requires Ruby 3.2.3 (see `.ruby-version`). MySQL is **not** needed for local dev.

```sh
bin/setup    # bundle, db:prepare, log:clear; tails into bin/dev
bin/dev      # foreman: web (rails s) + worker (bin/jobs) + css (tailwind:watch)
bin/rspec    # run the test suite
```

`bin/setup --skip-server` if you want to bootstrap without booting the dev server.

## Production Configuration

Production defaults to the MVP public app host and lets the deployment
environment override values that vary by cluster or mail provider:

- `SYRUS_APP_HOST` — optional public app host. Defaults to `agents.green-acres.estate`; used for URL generation, mailer links, and the default host allowlist.
- `SYRUS_ALLOWED_HOSTS` — optional comma-separated host allowlist. Defaults to `SYRUS_APP_HOST`.
- `SYRUS_ASSUME_SSL` / `SYRUS_FORCE_SSL` — optional booleans, both default `true` for TLS-terminating ingress/proxy deployments. `/up` is excluded from SSL redirects and host authorization for health checks.
- `SYRUS_MAILER_FROM` — optional sender address for application mail. Defaults to `Syrus <noreply@SYRUS_APP_HOST>`.
- `SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_AUTHENTICATION`, `SMTP_ENABLE_STARTTLS_AUTO` — optional SMTP settings. When `SMTP_ADDRESS` is absent, Rails keeps its default mail delivery configuration and delivery errors are not raised unless `SYRUS_MAILER_RAISE_DELIVERY_ERRORS=true`.

## Per-Issue Controls

Syrus recognizes `syrus-skip-prepare` on a source issue as an escape hatch for
broken prepare commands. Jobs ingested with that label skip the prepare step and
start at implementation; removing the label restores the normal prepare-first
workflow on the next ingest.

## Naming

Named after [Publilius Syrus](https://en.wikipedia.org/wiki/Publilius_Syrus),
the 1st-century-BCE Roman writer whose *Sententiae* — a collection of
one-line maxims — were schoolbook material for over a millennium and seeded
a surprising number of phrases still in everyday use. He was a writer, same
job the LLM is doing inside this harness, and his output outlived him by
two thousand years. That's the aspiration: small, durable text that
compounds. Thomas first encountered him in high-school Latin readings.
