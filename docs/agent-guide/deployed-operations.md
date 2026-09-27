## Testing on the deployed instance

To exercise a change end-to-end, configure a low-stakes GitHub test
repository that your deployed Syrus instance polls. Set
`SYRUS_TEST_REPO` to its `owner/name` slug, then file an issue on that
repo with the `syrus` label — the deployed Syrus instance picks it up
and opens a PR there:

```
gh issue create -R "$SYRUS_TEST_REPO" --label syrus \
  --title "..." --body "..."
```

For Syrus Epics, the body must contain the marker line. The title alone is not
enough:

```
Epic: <epic name>

## Goal
...
```

Child issues that belong to that Epic use `Epic: #<epic-issue-number>` in
their body. If you create the Epic and child issues in one batch, verify the
Epic record exists in Syrus before filing children, or create the Epic through
the admin API first.

For production Syrus inspection or operations, prefer the bearer-token admin API
before shelling into Kubernetes or running Rails console commands. Local admin
API credentials are stored in `~/.syrus/credentials`.

Don't run `bin/dev` and stub things to simulate the agent — file a
real issue and watch the real flow. Test issues should be small
(single-PR scope), low-stakes, reversible, and describe real (if
frivolous) improvements — the agent actually implements them.

**Now the important part: be actually funny.** The model defaults
to a tepid productivity-blog register — bullet points, neutral verbs,
"considerations." For test-repo issues, override that hard. The
target is "fun to read," not "looks like a Linear ticket." Specifically:

- Lean into the namesake's mock-Roman gravitas. Frame trivial UI
  tweaks as moral obligations to a long-dead aphorist. Treat
  six-line static Latin footers like constitutional crises.
- The "Out of scope" section is comedic gold — list specific,
  absurd things the agent must NOT build. Use it.
- Running bits are good. Callbacks are good. Lampshaded
  over-engineering is excellent. Deadpan absurdity beats winking.
- Give the agent attitude in the body. It will not file a complaint.

The model is genuinely good at this when you let it. The repo is
usually private, the audience is future-you and the agent that picks it up.
Make it a good time. If the issue body reads like something you'd
actually post in a customer-facing tracker, you've under-reached.

## Debugging deployed environments via kubectl

Use the kubeconfig, namespace, and deployment names for your own
Syrus deployment. Keep them in env vars so examples stay portable:

```bash
export SYRUS_KUBECONFIG="${SYRUS_KUBECONFIG:-$HOME/.kube/config}"
export SYRUS_NAMESPACE="${SYRUS_NAMESPACE:-syrus}"
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" get pods
```

**Pod label gotcha:** Syrus manifests commonly label pods
`name=syrus-worker` / `name=syrus-web`, NOT `app=...`. Adjust the
selector if your deployment uses different labels:

```bash
POD=$(kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
       get pods -l name=syrus-worker -o jsonpath='{.items[0].metadata.name}')
```

**Logs.** The container name is `syrus-worker` (with a `fix-perms`
init container — `kubectl logs` complains about "defaulted to" if
you don't pass `-c`). Worker logs are noisy with ActiveJob
serialization; grep for the bits you need:

```bash
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
  logs deployment/syrus-worker --tail=500 \
  | grep -E "PollAllMergeStates|PollMergeStateJob|PollRebaseJob|preempted|RunJob|FAIL"
```

**Rails console / runner.** Don't try to inline complex Ruby into
`bin/rails runner '...'` — kubectl's shell escaping mangles
backslashes inside string literals (`\1` regex backrefs, `\"` escapes
in dig calls, etc). Write the script to `/tmp/script.rb` locally,
`kubectl cp` it in, `bin/rails runner /tmp/script.rb`:

```bash
POD=$(kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
       get pods -l name=syrus-worker -o jsonpath='{.items[0].metadata.name}')
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
  cp /tmp/diagnose.rb $POD:/tmp/diagnose.rb -c syrus-worker
kubectl --kubeconfig "$SYRUS_KUBECONFIG" -n "$SYRUS_NAMESPACE" \
  exec $POD -- bin/rails runner /tmp/diagnose.rb
```

**Useful diagnostic recipes** (run via the pattern above):

- *Active / zombie Runs* — `Run.where(state: %w[queued running])`.
  A "running" Run whose worker process is dead = zombie;
  `ReapStaleRunsJob` (runs every minute) handles these automatically.
- *Solid Queue history for a Run id* — `SolidQueue::Job.where(class_name: "RunJob")`
  filtered by `j.arguments&.dig("arguments")&.first == run_id`.
  Look for `j.failed_execution&.error&.dig("message")` for the death cause.
- *Bare clone worktree state* — `git worktree list --porcelain`
  inside `/syrus-home/.syrus/clones/<repo_id>.git`. Don't use
  `--verbose` with `--porcelain` (mutually exclusive in git 2.39).
  For real ground truth, walk `<bare>/worktrees/*` directly — list
  hides corrupted-HEAD entries.
- *Held semaphores (concurrency locks)* —
  `SolidQueue::Semaphore.all` — keyed `RunJob/job:<id>` etc.
  Stale locks past `expires_at` get released on next dispatcher tick.

**Token redaction is on the DB-write path, not the read path.** If
you query `JobLog.chunk` or `SolidQueue::FailedExecution.error` in
the rails runner *before* a redaction-aware build is deployed, you
will see plaintext tokens. **Never copy that output to chat.** When
scrubbing, write a redaction script (regex
`%r{(https://x-access-token:)[^@\s]+(@)}`) and run it in-process via
`kubectl cp` + `bin/rails runner` — same pattern as diagnostics.

**Deploys SIGKILL in-flight Runs — and used to get blamed on the host.** A
rollout drains workers with SIGTERM *and* spikes CPU/IO across every node
(image pulls, pods starting and dying), so `RunFailureClassifier` saw a dead
process on a "critical" host and recorded the non-retryable
`worker_died_under_resource_pressure` instead of retryable `worker_died`,
stranding the Job. It now treats two distinct worker `InstanceVersion` versions
starting within `DEPLOY_ROLLOVER_WINDOW` of the failure as a rollout and stays
retryable.

**Deploys SIGKILL in-flight Runs — after 5 seconds, not the grace period.**
Every `bin/deploy` rolling restart kills any active RunJob mid-perform.
The worker pods carry `terminationGracePeriodSeconds: 600`, which reads
like a ten-minute drain window, but `SolidQueue.shutdown_timeout`
defaults to **5 seconds** and Syrus does not override it: the supervisor
waits 5s for its children and then kills them. Measured termination in a
production rollout was 6–13 seconds. So the grace period is not
load-bearing, and no amount of rollout staggering protects in-flight
Runs — recovery is `ReapStaleRunsJob` plus auto-retry, not draining.
Raise `SolidQueue.shutdown_timeout` if you ever want Runs to survive a
deploy. RunJob's `ensure` cleanup may not finish; orphan
worktrees and zombie Runs can accumulate. `ReapStaleRunsJob` marks dead
Runs failed and schedules the same auto-retry path used for other failures;
agentic runs with captured sessions resume from the failed Step when possible.
If you see a "refusing to fetch into branch X checked out at /worktrees/N"
error post-deploy, it's a stale registration — clean by walking
`<bare>/.git/worktrees/*` and force-removing whose Run is terminal-or-zombie.

## Workflows

Local dev:

```
bin/setup          # initial install + DB
bin/dev            # foreman: web + worker + tailwind:watch
bin/rspec spec/jobs/run_job_spec.rb   # one Ruby spec file
bundle exec rspec spec/jobs/run_job_spec.rb:42 # one Ruby example
npm run test:react # React/Vitest suite + TypeScript typecheck
bin/test           # Ruby and React suites; reports separately
```

React tests run through Vitest and TypeScript. Use `npm run test:react` for
frontend-only changes when a focused Vitest command is not enough, or
`bin/test` to chain Ruby and React.

Syrus repository grading is declared with typed RSpec and Vitest graders in
`.syrus.yml`. The plugins synthesize full, focused, and CI-phase commands plus
test-result output and base-revision retry behavior.

Use CI-only specs sparingly. They are for checks that are too slow, too
environmental, or too broad for normal agent grade loops but still important in
GitHub Actions. A future agent should run CI-only specs when working on a CI
failure workflow, when changing CI/test infrastructure itself, or when the
change touches behavior that is only covered by an existing `:ci_only` spec. Do
not add a spec to `:ci_only` merely because it is failing or inconvenient; first
try to make it fast with fakes, dependency injection, or a narrower assertion.

`bin/rspec` and Rails boot load `config/syrus_bundle_env.rb` before
Bundler setup so prepared bundles under `.syrus/deps/bundle` or
`vendor/bundle` work. Ruby grader commands in `.syrus.yml` intentionally
run `bundle config set --local path vendor/bundle && (bundle check ||
bundle install --jobs 4)` before Rails/RSpec checks; keep that pattern
when editing graders.

Docker (production image):

```
docker build --platform linux/amd64 -t syrus:amd64 .
```

The image is single-purpose (worker pod overrides CMD to `["./bin/jobs"]`);
web pod uses the default `./bin/thrust ./bin/rails server`. See
"Deploy target" below for the amd64 / Apple Silicon gotcha.

Deploying to Kubernetes:

```
bin/deploy                # default deployment target
bin/deploy --staging      # staging target, if configured
bin/deploy --production   # production target, if configured
bin/deploy --skip-build   # assume :<sha> already pushed
```

Reads the GHCR PAT from `$GHCR_TOKEN` or
`~/.config/syrus/ghcr-token` (chmod 600). Builds the configured image
platform, pushes the configured image repository tags, runs
`kubectl rollout restart` on `syrus-web` and `syrus-worker`, and waits
for rollout status. It also builds and pushes every plugin service image
(`plugins/*/container`, named by `syrus_plugin_images` in
`bin/docker-image-lib`) at the same SHA, pins any workload running one --
found by image, whatever the cluster names it -- plus the matching Flux image
overrides, and waits for those rollouts too. Configure kubeconfigs, namespaces, registry, and
image repository for your own environment before relying on this script.

## Deploy target

Build images for the CPU architecture used by your cluster nodes
(commonly `linux/amd64` or `linux/arm64`). On Apple Silicon, make sure
your Docker/buildx setup can build the target platform efficiently; QEMU
emulation can make cross-architecture builds much slower.

Required runtime env:

- `RAILS_MASTER_KEY` — credentials decryption unless all three
  Active Record encryption env keys are provided separately
- `SECRET_KEY_BASE` — sessions, signed cookies
- `DB_HOST`, `SYRUS_DATABASE_PASSWORD` — primary MySQL
- `SYRUS_DATA_ROOT` — defaults to `/home/rails/.syrus`. Mount a PVC
  here on worker pods so the bare-clone cache survives restarts.
  Web pods don't need this volume.

