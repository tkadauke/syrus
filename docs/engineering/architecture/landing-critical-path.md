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

## Expected effect

Per round: 2-3 minutes off the fan-out, 0.3-1.5 minutes off the slowest
grader's setup, and 1-2 minutes (up to 5) off its post-command ingestion —
roughly **4-6 minutes per round**, so 8-12 minutes off a median two-round train
(110 → ~100) and more on long trains. Nothing here changes which graders run or
what they check.

## Remaining gap to 15 / 45

A happy-path round is still about 40 minutes against a 15-minute budget. In
rough order of leverage:

1. **Rounds.** Median two, p90 four. Every avoided round saves 30-45 minutes —
   more than every other item combined. Repair rounds that re-run the full
   RSpec CI suite (the repair touched a suite-wide input, so no focused
   substitute applied) are the expensive ones.
2. **Shard CPU grants.** Partitioning by recorded runtime assumes equal CPUs.
   Either require a minimum grant before a shard starts, or let shards pull
   files from a shared queue (work stealing) so a 3-CPU host simply does less.
   With even grants the eight-shard CI suite is ~10-12 minutes.
3. **The refresh itself.** Moving it off the grader does not make the three
   aggregate reads cheaper; at 70-100 s each they load the database every
   grader. They want an index-backed or incremental formulation.
4. **Per-grader setup on crowded hosts.** Overlay mounts are unavailable in the
   pods, so every grader hard-links the full tree; enabling the overlay (or
   pruning stale refs once in the shared layer) removes most of the remaining
   setup.
5. **Start graders as soon as their inputs exist.** Build → prepare →
   reconcile → fan-out is serial (~6.5 min median). The reconcile review could
   run beside the graders when it produces no commit.
6. **Fail-fast repair.** A round waits for its slowest grader even after a
   required grader has failed (one round waited 12 minutes after a
   0.2-minute failure). Starting the repair on the first required failure
   trades a fuller evidence set for a shorter round.
7. **Merge-train build conflicts.** The 26-51 minute builds are agent conflict
   resolution on Epic hotspot files; preparing the build workspace's
   dependencies before the agent starts would save its 1.5-3 minute
   `bundle install`.
