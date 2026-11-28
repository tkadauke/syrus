# Landing critical path

Where a merge train's wall-clock time goes, measured from production, what was
changed to shorten it, and what still stands between today and the operator's
target: **15 minutes for a happy-path land, 45 minutes for one repair round**.

The measurements below come from two weeks of production merge-train and
auto-merge workflows (Step/Run `started_at`/`finished_at` and job-log
timestamps inside long Steps), read-only. Minutes unless noted.

## Measured breakdown

### Whole workflows

| | n | median | p90 |
|---|---|---|---|
| merge train, succeeded | 84 | 110 | 293 |
| auto-merge (single landing), succeeded | 52 | 11 | 102 |
| merge-train grading rounds per workflow | 110 | 2 | 4 (max 7) |

A merge train is a serial chain — assemble, build, prepare, reconcile,
fan-out, graders, collect, then either land or `landing_fix` and another
fan-out/collect round. **The number of rounds is the dominant multiplier**: 30
of 110 trains finished in one round; the rest paid 2-7.

### One round

| phase | median | p90 | what the time is |
|---|---|---|---|
| assemble | 0.0 | 0.0 | |
| `merge_train_build` | 1.7 | 9.8 | integration rebase; the 26-51 min outliers are agent conflict resolution (one hotspot file across an Epic), including `bundle install` (1.5-3 min) in a workspace that `prepare` has not yet prepared, and repeated plugin-boundary / spec runs |
| `prepare` | 1.3 | 2.1 | |
| `merge_train_reconcile` | 1.5 | 4.6 | agent semantic-conflict review |
| `grader_fanout` | 2.7 | 5.2 | **~75% fingerprint hashing** (below) |
| fan-out start → collect end | 43-50 | 92-98 | long pole is an RSpec CI shard in ~80% of rounds |
| `landing_fix` | 2.5 | 9.2 | agent repair |
| collect, land | <1 | <3 | |

Create → first fan-out start: median 6.5-7, p90 33-38.

### Inside `grader_fanout`

A 5-minute round-one fan-out (25 graders selected of ~150 targets):

- 0 → 30 s: workspace setup and plan compile.
- 32 → 206 s: **silent** — `record_ci_phase_target_set!` fingerprints every
  CI-phase target (≈150), and every `Fingerprints` instance re-ran
  `git ls-files` and SHA256'd its whole source scope from scratch (twice:
  once for the payload, once for the metadata count). Repo-wide targets match
  every tracked file.
- 206 → 244 s: target-health lookups, one per selected grader, ~1.5 s each —
  again a fresh fingerprint (and full re-hash) per target.
- 244 → 267 s: snapshot record, prepared-archive upload (673 MB, 13 s),
  publish, materialize.

Repair-round fan-outs showed the same 195-253 s silent gap with only 3-6
graders selected, because the CI-phase manifest still fingerprints every
target. This is the "fan-out silent for minutes" symptom.

### Inside one grader

Per-grader wall = queue wait + checkout setup + command + post-command.

| example | setup before command | command | post-command |
|---|---|---|---|
| `migration-collisions`, crowded host | 202 s | 2 s | 18 s |
| `eager-load`, quiet host | 83 s | 14 s | 2 s |
| `rspec-ci-1-of-8` | 41 s | 655 s | 58 s |
| `react-tests-ci`, crowded host | 236 s | 1310 s | 305 s |

Setup, from job-log timestamps:

- prepared-layer lookup under the host IO gate, hard-link materialization
  (overlay mounts are denied in the pods, so every grader hard-links ~69,000
  entries): 5-35 s.
- snapshot fetch from the hosting platform (the mirror never has snapshot
  refs): 1-2 s.
- base-branch fetch: 5-13 s, and **done twice** — once by the restore path,
  once again by `setup`.
- **stale remote-tracking ref pruning**: the prepared layer carries every branch
  its workspace ever saw; each was deleted with its own `git update-ref`
  subprocess and its own synchronous job-log insert. 0.25 s × hundreds = 77 s
  on the crowded example.
- target fingerprint refresh (one target, whole-scope hash, previously twice),
  tracked-file validation, grader-input materialization: 12-100 s depending on
  host load.

Post-command is test-result ingestion (`TestInsights::Ingester`): the TestRun
and TestCase rows are written within a second of the command ending, then
56-286 s pass before the ingestion completes, inline, on the critical path of
every test grader. Timing the reads behind `TestIdentity.refresh_many!` for
one 8,045-identity grader in production: `latest_cases_for` 103 s,
`latest_status_times_for` 88 s, `RecentStats.load` 73 s. The summary refresh
is essentially the whole post-command phase.

### RSpec shard imbalance is CPU-grant imbalance

Shards are partitioned by recorded per-file runtime and are close in work, yet
one round's eight shards took 3.3 to 16.8 minutes. The shard logs show why:
`-n 12` on one host, `-n 3` on another. A shard granted 3 CPUs takes five times
as long as one granted 12, and the round waits for the slowest. Queue waits add
p90 5-30 minutes when the fleet is crowded.

## Changes in this pass

1. **Hash each workspace file once per fan-out.**
   `TargetGraph::FileDigests` memoizes the tracked-file list, glob matches and
   per-file digests for one unchanging workspace; `Steps::GraderFanout`, its
   `TargetHealthReuse`, and `Steps::PreflightGraderFanout` share one instance,
   and a single `Fingerprints#for_target` no longer hashes its scope twice.
   Fingerprint values are byte-identical (specs compare shared against
   unshared), so target-health records and carry-forward keep matching.
   Expected: fan-out 2.7 → ~0.7 min median, 5 → ~1.5 p90, **every round**.
2. **Batch stale-ref pruning** into one `git update-ref --stdin` transaction
   with one summary log line. Expected: up to ~75 s off each grader's setup on
   layers with many leftover branches.
3. **One base-branch fetch per grader setup.** The restore paths already fetch,
   prune and verify the base ref; `setup` no longer repeats it. Expected: 5-13 s
   off every grader.
4. Grader fingerprint refresh hashes its scope once instead of twice (part of
   change 1).
5. **Test-identity summary refresh off the grader.** `RefreshTestIdentitiesJob`
   (plugin queue) runs `TestIdentity.refresh_many!` and then enqueues search
   indexing, which reads the refreshed columns. TestCase rows and the
   WIP-repair classification stay inline: flakiness adjudication and failure
   evidence read those, not the identity summaries. Expected: 1-5 minutes off
   every test grader, including the round's long pole.
6. **Minimum CPU grant for RSpec CI shards.** A whole-host grader's declared
   `cpu_min` is now an admission input: a worker whose grant would fall below
   it (too small, already booked by whole-host peers at their own minimums,
   or memory-bound below that width) refuses the Run with the reroutable busy
   reason, so the router moves it to a worker that can. After
   `RunHostAdmission::CPU_MIN_PATIENCE` (10 minutes) the shard starts
   wherever it is, so a crowded fleet is slower, never stuck.
   `parallel_rspec.shard_cpu_min` sets the shards' minimum; this repository
   declares 6, the width at which a shard measured ~11 minutes of test time.
   The default (2) leaves other repositories' behaviour unchanged. Watch
   `resource_guard_binding_terms: grader_cpu_min_unavailable` in admission
   decisions to see it act.

## Why trains need more than one round

Round-one failures of the last two weeks' merge trains, classified by the
round-one repair's diff against each member's own changes:

| round-one outcome | trains | share | median rounds |
|---|---|---|---|
| passed | 35 | 31% of 114 | 1 |
| interaction: the repair touched code from two or more members | 39 | 49% of failures | 3 |
| one member's own code (the repair stayed inside one member's files) | 18 | 23% | 3 |
| cross-member inventory specs (`spec/docs`, `spec/i18n`, host-surface and tool-catalog audits) plus a code fix | 8 | 10% | 3 |
| repair changed nothing: inconclusive no-op or explicit flaky retry (flake / infrastructure) | 10 | 13% | 2-4 |
| purely derived artifacts (generated docs, catalogs, locales, registries) | 3 | 4% | 4 |
| other | 1 | 1% | 2 |

- Main moving is not a cause: the base-revision retry found none of the 467
  failed round-one graders inherited from main. Grader timeouts were 12 of 467.
- Round-one pass rate falls with train size: 2 members 52%, 3 members 32%,
  4 members 27%, 5 or more members 20%.
- Almost every round-one failure is in the CI-phase suites (RSpec CI shards,
  the serial pass, plugin CI suites, boundary and boot checks), which no
  member runs before it joins a train: member review grades are focused. The
  repo-wide audits (catalogs, i18n debt, host-surface inventory, Current.user
  scope audit) appear in 65% of failed rounds, alone or beside behavioural
  failures.

What that points at, in order:

1. **Smaller trains, or train composition by overlap.** Half the failures are
   interactions, and they grow with member count. Capping a train at 2-3
   members, or splitting members that touch the same hot files (the plugin
   host API, tool catalogs, `config/application.rb`, `AdminPlugins.tsx`),
   attacks the largest bucket.
2. **Pre-train CI validation of each member.** The 23% that are one member's
   own code would be caught by running the CI-phase suites on the member
   before it joins, off the train's critical path.
3. **Regenerate derived artifacts after integration.** Catalogs, generated
   plugin docs and locale debt files are deterministic. Running their
   generators in `merge_train_build` after the rebase would remove the
   artifact-only failures and part of the mixed ones.
4. **Flake handling** is the smallest bucket (13%).

## Expected effect

Per round: 2-3 minutes off the fan-out, 0.3-1.5 minutes off the slowest
grader's setup, and 1-2 minutes (up to 5) off its post-command ingestion. The
shard minimum targets the long pole directly: shards measured 15-19 minutes
median and 35-46 p90 of test time at uneven widths, and should now run about
10-12 minutes at six or more cores, at the cost of up to ten minutes of queue
wait when no worker can grant six. Together that is roughly **10-15 minutes per
round**, so a median two-round train goes from 110 to about 75-85 minutes, and a
happy-path round from ~45 to ~25-30. Nothing here changes which graders run or
what they check.

## Remaining gap to 15 / 45

A happy-path round is still about 25-30 minutes against a 15-minute budget,
and the median train still pays two rounds. In rough order of leverage:

1. **Rounds** (see above). Every avoided round saves 25-45 minutes, more than
   everything else combined.
2. **Fail-fast repair, not implemented in this pass.** A round waits for its
   slowest grader even after a required grader has failed (one round waited 12
   minutes after a 0.2-minute failure). Doing this correctly means
   `grader_collect` must conclude with graders still running: the landing
   validation manifest, the grader-conclusion cache, multisect and
   `LandingRepairOutcome` all assume a terminal iteration today. The next
   fan-out would also need to tell a grader still running on the superseded
   HEAD from one that failed, and the reconciler's active-run-on-terminal-step
   repairs would have to tolerate it. A safe design: let collect close an
   iteration early only on a real (not infrastructure, not inherited) required
   failure, record the still-running graders as `superseded_in_flight` in the
   manifest (never cached, never counted as evidence for the new HEAD), and
   have the next fan-out treat them as unresolved so they re-run against the
   repaired HEAD. The immutable-HEAD review barrier is unaffected, because a
   repair that advances HEAD already supersedes all earlier evidence.
3. **Work-stealing shards.** The minimum grant evens the slow end; a fast
   worker still finishes its static slice early. Pulling spec files from a
   shared queue would let fast workers take more.
4. **The identity refresh queries.** Moving them off the grader does not make
   the three aggregate reads cheaper; at 70-100 s each they load the database
   on every grader. They want an index-backed or incremental formulation.
5. **Per-grader setup on crowded hosts.** Overlay mounts are unavailable in the
   pods, so every grader hard-links the full tree; enabling the overlay (or
   pruning stale refs once in the shared layer) removes most of the remaining
   setup.
6. **Serial pre-fan-out chain.** Build → prepare → reconcile → fan-out is
   ~6.5 minutes median. The reconcile review cannot be known in advance to
   produce no commit, so running it beside the fan-out means a speculative
   fan-out that is discarded if reconcile commits; not done here.
7. **Merge-train build conflicts.** The 26-51 minute builds are agent conflict
   resolution on Epic hotspot files. The agent spends 1.5-3 minutes on
   `bundle install` because `prepare` runs after the build; installing before
   the agent starts is unsafe mid-rebase (lockfiles can hold conflict
   markers), so this wants a shared dependency cache rather than a reordered
   prepare.
