# Deploying Syrus

## Two-version compatibility

A rolling deploy always runs two versions against one database, so every
release must be compatible with the one before it in both directions: new code
against the old schema, and old code against the new schema. Both halves have
caused production incidents here. The rule, the expand/migrate/contract
sequence, and how to read a new column defensively are in
[Rollout Compatibility](../conventions/rollout_compatibility.md).

## Client behavior during a rollout

The web Deployment runs `replicas=2` with `RollingUpdate(maxSurge=1,
maxUnavailable=0)`, so a ready pod exists throughout — but the ingress can
still answer `502` for the moment it keeps routing at a pod that has begun
terminating. In a browser tab that is a flicker; in an installed PWA it
replaces the app with a proxy error page the user cannot reload from, because
there is no address bar.

`app/views/pwa/service_worker.js.erb` closes that gap. It is registered from
the SPA layout and does exactly two things: it precaches
`/pwa/unavailable`, and it intercepts **navigation** requests only. When one
fails outright or returns `502`/`503`/`504`, it serves that cached page, which
polls `/up` with backoff and navigates back to the original path (remembered
in `sessionStorage` before the failure) once a backend answers.

What it deliberately does not do:

- **It caches no application assets.** A caching worker in front of digested
  Vite bundles is how a client ends up pinned to a build that no longer
  exists. Every request except a failed navigation is passed straight through.
- **It does not swallow application errors.** A `500` from Rails is the app's
  own error, not a rollover, and passes through to the app's error page; only
  gateway statuses are treated as "still coming up".
- **It is not a substitute for a graceful drain.** The fallback hides the
  symptom. Eliminating it means the ingress stopping routing at a pod before
  that pod stops accepting connections — a `preStop` drain delay on the web
  pods in the infrastructure repo.

The cache name carries the build SHA, so each deploy's worker drops the
previous cache on activate. `/service-worker.js` is served `no-cache` and
`skip_forgery_protection`, because Rails' cross-origin JavaScript protection
otherwise rejects a `.js`-format response fetched as a worker.

## Syrus Kubernetes rollout ordering

`bin/deploy` is a Ruby program. It loads no Rails -- it runs on an operator's
machine, against a cluster, before the image it is deploying exists -- and its
implementation lives in `lib/deploy/`, one file per phase, with
`lib/deploy/cluster_rollout.rb` holding the order a rollout runs in.

`bin/deploy --dry-run` changes nothing and prints the sequence of commands a
deploy would run, one `DRYRUN <command>` per line. Reads still execute, because
almost everything the deploy does is derived from live cluster state, and a dry
run that could not read would describe a deploy against a cluster it never
looked at. `DRY_RUN_STREAM=path` captures the stream to a file for diffing.

The previous Bash implementation is kept as `bin/deploy-legacy`. It takes the
same flags, including `--dry-run`, so the two can be compared rather than
trusted, and it is the fallback if the Ruby one is ever in doubt.

Syrus's own `bin/deploy` applies database migrations as an explicit
pre-rollout step. After images are built and pushed, and after Flux is
suspended/image overrides are pinned, the script creates a one-shot
`syrus-db-prepare-*` Kubernetes Job from the `syrus-web` deployment's runtime
environment. That Job runs the newly built app image with `./bin/rails
db:prepare` and must complete before any live workload is pointed at the new
SHA -- the web, worker, preview, and plugin service workloads alike.

Workloads are discovered by image rather than named in the script: every
container (init containers included) of a Deployment, DaemonSet, or StatefulSet
whose image repository is one Syrus publishes is pinned to the deploy's SHA, at
whatever tag or digest it currently runs. Changing the image is the only
rollout trigger; `bin/deploy` never issues a `kubectl rollout restart`, because
Flux strips the imperative annotation when it resumes and would replace every
pod a second time.

While that work runs, a cluster-side watchdog guarantees that Flux is resumed
if the deploy process exits before its cleanup runs. By default,
`FLUX_SUSPEND_TTL` is derived separately for each cluster from the enabled
pre-pull timeout, both migration budgets, discovered core and plugin rollout
targets, one additional rollout window, and `FLUX_SUSPEND_SLACK` (default
`5m`). Operators may set `FLUX_SUSPEND_TTL` to a fixed number of seconds, but
`bin/deploy` warns when that override is shorter than the computed budget.

This deliberately trades "new code against the old schema" for "old code
against the new schema" during the rollout. That is the safe direction only
when migrations are backward compatible with the currently running release:
add columns/tables/indexes first, keep old readers and writers working, and
land destructive or contract migrations only after the old code is no longer
running.

The web deployment *also* runs `db:prepare`, in its own `db-prepare`
initContainer, on every replica at every boot. Rails serializes migrations with
a MySQL advisory lock, so the pre-rollout Job and a web pod that happens to be
starting at the same moment -- a Flux reconcile mid-deploy, an eviction, a
crash-restart, or both replicas booting together -- race for it, and the loser
aborts with `ActiveRecord::ConcurrentMigrationError`. Losing that race means
another process is already applying the same migrations, so `bin/deploy` deletes
the Job and retries: `DB_PREPARE_ATTEMPTS` attempts (default `4`), waiting
`DB_PREPARE_RETRY_DELAY` seconds (default `20`) between them. Only that specific
error is retried -- a migration that genuinely failed stops the deploy on the
first attempt, and the failure message distinguishes a Job that failed from one
that ran out of its budget.

Before each retry, and before giving up, `bin/deploy` asks whether the work is
still outstanding at all: `db_prepare_satisfied` runs a short Job on
`${REGISTRY}:${SHA}` that exits zero when `needs_migration?` is false. The
process that won the lock runs the same migrations from the same image, so by
the time the loser is told "another migration is running" the schema may
already be where this deploy wants it, and continuing is correct. The probe
runs on the image being deployed rather than against a live web pod on purpose:
a running pod answers from the old image's `db/migrate`, which cannot contain
this release's migrations, and would report "nothing pending" for a database
that is genuinely behind.

That check exists because its absence cost a production deploy. Every attempt
lost the race to a web pod's `db-prepare` initContainer, the Job exhausted its
attempts, and `bin/deploy` rolled the image overrides back -- while the
migration had already been applied successfully by the pod that won.

### Two migration budgets, not one

Getting a migration pod running and applying migrations are separately
budgeted, because they fail for unrelated reasons and on unrelated timescales:

- `MIGRATION_START_TIMEOUT` (default `5m`) covers scheduling the pod, pulling
  the image and booting Rails. A container state that will never resolve on its
  own -- `ImagePullBackOff`, `CreateContainerConfigError`, an unschedulable pod
  -- fails the deploy immediately with the reason, instead of being waited out.
- `MIGRATION_RUN_TIMEOUT` (default `30m`) covers applying the migrations, which
  is legitimately long: Syrus has shipped single data migrations that rewrote
  tens of thousands of rows. While it runs, `bin/deploy` reports elapsed time
  and the migration Job's latest log line every 30 seconds, so a slow migration
  and a wedged one do not look alike.

`DB_PREPARE_TIMEOUT` is still honoured and sets the migration run budget, which
is what raising it has always been used for. Both accept seconds or a compound
duration such as `1h30m`. The Job's own `activeDeadlineSeconds` is derived from
the sum of both budgets, so Kubernetes never kills a migration before
`bin/deploy` decides to.

A single shared budget is what made this worth separating: one ten-minute clock
covering both phases failed a production deploy -- and rolled it back -- over a
data migration that was running correctly and would have finished.

### An interrupted deploy never kills a running migration

Deleting a Kubernetes Job propagates to its pod, which means SIGTERM to Rails
in the middle of whatever it is applying: a half-finished `ALTER`, a backfill
stopped at an arbitrary row. So `bin/deploy` will not delete a migration Job
whose pod is still running, on any path -- a failure elsewhere in the deploy,
`SIGTERM`, or Ctrl-C. It reports that it left the Job alone and prints the
`kubectl logs -f` command to watch it:

```
⚠ left migration job/syrus-db-prepare-… in place: it is still applying
  migrations — watch it with `kubectl logs -f -n syrus-production job/…`,
  and deploy again once it finishes
```

A Job that has finished is deleted as usual; only an active one is spared.

Worker containers also check `db:abort_if_pending_migrations` before starting
`bin/jobs`. In a normal deploy that check is already satisfied by the
pre-rollout Job. If a worker is started against a database that is still behind
the image, it exits loudly before it can claim Solid Queue work.
