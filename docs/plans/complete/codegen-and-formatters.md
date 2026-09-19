# Codegen, formatters, and graders — pipeline step taxonomy

_Captured 2026-07-18. Design discussion only; no implementation yet. Builds on
the grader `when_files_changed` work (PR #1791, merged)._

_Status check 2026-09-19: complete. The proposed `generated:`/`formatters:`
taxonomy, diff-scoped self-gating, and `codegen_ignore` handling all shipped
(`app/services/steps/generate.rb`, `app/services/steps/format.rb`,
`app/services/syrus_yml.rb`) and are documented as current behavior in
CLAUDE.md's Key steps section and `config/syrus_docs/syrus_yml.md`. Retained
as design history._

## Context

Syrus already has **graders**: commands declared in `.syrus.yml`, materialized
as `grader` Steps at `grader_fanout`, aggregated by `grader_collect`, and driven
by `Workflows::RetryUntil` (bounded by `AppSetting.grade_max_iterations`). A
grader is a **check**: when it fails, its output is fed back to the agent as a
repair iteration, and the agent edits + commits the fix through the normal
`commit_agent_changes` loop. PR #1791 (merged) added an optional
`when_files_changed` glob array per grader so slow/irrelevant checks (e.g. a
website build) are skipped when the PR didn't touch matching files; its
`git diff --name-only <base>...HEAD` logic in `Steps::GraderFanout` is the seed
for the shared changed-files primitive proposed below.

This plan extends that model with two more categories that are **not** graders,
because they don't just *check* — they *produce or modify* files. The full
taxonomy is three kinds:

| Kind | What it does | Who applies changes | Failure semantics | When it runs |
| --- | --- | --- | --- | --- |
| **generated** (codegen) | Derives checked-in files from source | Deterministic; the step regenerates | Correctness — a stale artifact is a *lying* commit; hard-fail only if the generator can't run | First (outputs feed everything downstream) |
| **format** | Cosmetically rewrites files in place | Deterministic; safe-autocorrect | Cosmetic — fail soft | After codegen, before graders |
| **grade** | Judgment checks | The **agent** (repair loop) | Real defect — agentic repair | Last, on the healed/formatted tree |

Everything runs **inside** the `retry_until` body — `retry_until(implement →
codegen → format → graders)` — because each agent repair iteration re-dirties
the tree, so a one-shot "generate/format then grade" doesn't hold. Each iteration
regenerates + reformats so the graders always see a fully-built, formatted tree.

## Formatters

**A formatter is intrinsically self-gating; it does not need PR #1791's
mechanism.** Its input set *is* the changed files of its language:
`rubocop -a $(git diff --name-only <base>...HEAD -- '*.rb')`. If no `.rb`
changed, the file list is empty and the step is a natural no-op. So the gate is
**mandatory and derived from the formatter's own target language**, not an
optional operator-declared glob. `rubocop` → `*.rb`, `prettier` →
`*.{ts,tsx,css}`, each self-skips when its slice of the diff is empty. Reusing
`when_files_changed` here would just re-declare what the formatter already knows.

Rules:

- **Safe-autocorrect only** (`rubocop -a`, never `-A`). Safe autocorrect is
  semantics-preserving by RuboCop's contract; unsafe (`-A`) may change behavior.
- **Ordering is a safety net, not just cosmetics.** Because the graders (rspec,
  eager-load) run *after* the formatter, the test suite *validates the
  formatter's output* — even a theoretically-unsafe autocorrect that changed
  behavior gets caught before PR/land.
- **Fail soft.** If the agent produced unparseable Ruby, rubocop can't
  autocorrect — don't crash the step; let the graders surface the real problem
  (same philosophy as `prepare`'s soft-fail).
- **Scope to changed files.** A whole-repo `rubocop -a` on a never-formatted
  codebase reformats thousands of untouched files — the first Job would produce
  a massive churn diff.
- **Idempotence** is what makes the loop terminate (a non-idempotent formatter
  oscillates with the agent forever). Safe-autocorrect is idempotent.
- **Amend** while pre-PR (initial/retry) is free; in feedback workflows the
  branch is already pushed, so an amend implies `push --force-with-lease`
  (precedent exists in the rebase steps).
- **Generalizes past Ruby**: `prettier --write` / `eslint --fix` are the
  frontend formatters; ESLint rules needing judgment are graders.

## Generated files (codegen / builders)

Codegen = **code generated from code** (proto/gRPC stubs, GraphQL→types,
OpenAPI→client, sqlc, route manifests, typed schema, etc.). Not a compiler/build
system — the distinguishing property is a **checked-in derived artifact that
must equal `f(source)`**. This is the correctness-load-bearing tier: a stale
format is an ugly PR; a stale build is a lying commit (types that don't match
runtime, RPC stubs out of sync, a manifest referencing a deleted handler).

### Two globs

- **input glob** (`sources:`) — the **rebuild gate**. If none of the declared
  source inputs changed, regenerating produces identical output (deterministic
  generator), so skip. The robust implementation is a **content hash** over the
  input set compared to the last generation, rather than a raw `git diff` match:
  a deterministic generator over byte-identical inputs is *provably* identical
  output, and hashing removes the "did the glob happen to match" guesswork for
  the intra-loop case (which is where the cost actually is).
- **output glob** (`generates:` / `files:`) — serves multiple consumers:
  1. **Formatter-exclude** — the formatter must not touch generated paths or it
     fights the generator's own style forever.
  2. **Fast-path veto** — the input-gate may skip regen only if inputs are
     unchanged **and** no output path was touched. Otherwise an agent that
     hand-edits a generated file *without* touching source slips straight
     through the optimization undetected. If outputs moved, force regen+compare.

### Detect, not prevent

An earlier idea was to make generated paths **read-only to the agent** (deny
`Write`/`Edit`). **Rejected** — it casts too wide a net and blocks real fixes:
partially-generated/partially-hand-maintained files, manual override blocks,
generator templates under overlapping globs, one-off legit edits while the
source-of-truth catches up. Prevention fails closed on cases you didn't foresee;
**detection degrades gracefully**. So: detect, heal, and *note* — never block.

### Detection via bit-comparison (outcome-based, not action-based)

Do **not** decide by "did the agent's diff touch an output path." Instead:
**regenerate from committed source, diff against the committed outputs.**
Identical → fine; different → out of sync. This is strictly better because it's
outcome-based — it doesn't matter *how* the file got there (agent ran the
generator, agent left it alone, agent hand-edited to coincidentally-correct
output all collapse to "regen == committed → fine"). It's the same regen-and-
compare that is already the correctness check, so detection and correctness are
one pass, with **no false positive on an agent that did the right thing**.

On divergence: **auto-heal** (regenerate in place, amend so HEAD becomes
correct) and surface a note. If the agent had put *real intent* in a generated
file, the heal reverts it and the **grader loop is the backstop**: the test that
depended on that behavior goes red next iteration and the agent is forced to redo
it in source. You never need to perfectly classify "stale vs meaningful
hand-edit"; you heal to source-truth and let the graders catch any reverted
behavior. (Residual risk is only *untested* hand-edited behavior — already broken
the moment it lived in generated code.)

### Bad base / attribution — the core principle

**The pass/fail gate is the correctness of the *healed* HEAD — never attribution,
never the state of the base.** You grade the tree after codegen-heal + format,
and if it's green and source-consistent, the job passes, full stop. This is the
same stance as "we don't fail a job for fixing an unrelated failing test — we
*force* it." Races happen; a job's base snapshot can be momentarily bad (stale
codegen, a red unrelated test). We must not **fail** a job for producing a
**correct** outcome just because the base was bad.

Consequences:

- Codegen **heals and continues**, it does not heal-and-adjudicate. The only
  codegen hard-fail is *inability to produce a correct artifact* — the generator
  itself erroring — which is failing on "can't be correct," categorically
  different from "base was bad."
- **Idempotent convergence makes the redundancy free, and codegen is the best
  case for it.** When a feature job and a main-repair job both regenerate the
  same stale files, deterministic codegen produces bit-identical output → zero
  merge conflict. It's self-limiting: whoever lands first cleans main, so later
  jobs find a clean base and their heal collapses to a no-op. The main-repair
  job is a **dedup optimization** (spare N jobs the same regen), not a
  precondition — you never block jobs behind "main is provably clean first,"
  because races guarantee that's sometimes false.
- **The residual failure that survives is always real.** Agent hand-edited only
  generated files, clean base, heal reverts to a no-op → the job fails only if
  its task had a regression test (the bug is still unfixed — correct), or
  resolves as `no_changes` (empty PR — the operator sees the agent did nothing).
  In neither branch did "you touched generated files" or "the base was stale"
  become the failure reason.

### Base-diff capture (isolating agent-caused divergence)

`regen(HEAD_source)` vs `HEAD_output` measures **total** staleness (pre-existing
+ agent-caused). With a stale base it fires on an innocent (or helpful) agent, so
you can heal on it but you **cannot attribute** on it. To attribute honestly,
baseline the base:

1. **After prepare, before the agent:** run the generator on the base checkout,
   capture `base_diff` (generated-path `git diff`), record it as a workflow
   artifact, then **revert the generated files** (`git checkout -- <generated>`)
   so the agent starts from the *actual committed* base. (Blanket-do-it is
   simpler than "only if there's doubt"; the cost is one generator run, gated on
   the repo declaring codegen at all.)
2. **At the end:** regenerate on HEAD, get `head_diff`, heal in place.
3. **Attribute (note only, never fail)** by combining `source_changed`,
   `output_changed`, and `base_diff`:
   - `output_changed && !source_changed && base_diff empty` → **unambiguous
     hand-edit** (a real regen would've been a no-op). Heal → net-empty →
     `no_changes`.
   - `output_changed && !source_changed && base_diff non-empty` → **probably a
     legitimate staleness repair**; defer to `head_diff` (if the healed output
     matches, the agent did something good, and `base_diff` proves it wasn't its
     mess).

**Do not auto-file a repair Job from `base_diff`.** A non-empty `base_diff` does
mean main is carrying stale codegen — but a feature job must **not** file a
repair Job off it. Every job that races onto the same stale base would
independently file one, which is a race-condition / thundering-herd trap.
`base_diff` is recorded for **attribution only** (so the agent isn't blamed for
pre-existing rot). Repair-filing stays owned by the main-health path, which
detects stale main on its own cadence (once codegen is one of its base-layer
checks) and files exactly one deduplicated repair — same single-trigger
discipline as broken-main. **Cost:** you usually don't pay for two full generator
runs — the input-gate reuses the recorded baseline when nothing moved (`head_diff
== base_diff`); you only re-run when a source input changed or an output was
touched.

**Design fork — revert vs keep:** instead of capture-then-revert you could
capture-then-**keep** (codegen-heal the base right after prepare so the agent
always starts codegen-clean, making end-attribution trivial). It costs a bit of
scope creep (the job's diff absorbs the base-staleness fix) but that's harmless
and self-limiting per the convergence principle. Capture-and-compare keeps the
job's diff tighter; pre-heal keeps the logic dumber. Pick based on how much you
care about unrelated regen showing up in a feature PR.

### "Codegen-ignored" files (e.g. `schema.rb`)

A generated file can be committed **for human reasons** (PR reviewability, fast
`db:schema:load`) yet be **correctness-exempt** from the `regen == committed`
assertion. `db:schema:dump` is a **non-deterministic generator across the
contexts where it runs**: SQLite (dev/test) vs MySQL (prod) produce different
`schema.rb`, and the dump also depends on migration order and schema version. So
there is **no single canonical `gen(source)`** to diff against — `schema.rb` is
*structurally ineligible* for the assertion. "Codegen-ignored" is simply what you
call a generated file whose generator fails the determinism precondition: not
gitignored, but codegen-ignored.

Semantics: its **textual** correctness doesn't matter; its **functional**
correctness still does (migrations apply cleanly, no pending migrations, app
boots, tests pass against the migrated DB) — and that's owned entirely by the
**graders**. Same validation model as a gitignored generated file (runtime-
checked, never diff-checked); it just happens to live in the tree. This is
already the repo's reality: `schema_format = :sql` in prod, `schema.rb` from
SQLite in dev/test, prod migrating from zero → prod never loads those bytes.

In the taxonomy this is a per-path flag: **asserted** (deterministic generator →
`regen == committed` enforced + healed + hand-edit-detected) vs **exempt /
codegen-ignored** (non-deterministic → committed but grader-validated). An exempt
path drops out of the codegen step (no staleness assertion, no hand-edit alarm)
and into the graders' lap, while still getting formatter-exclude and its
`DO NOT EDIT` header. Even the `schema.rb`-specific worry — agent edits
`schema.rb` instead of writing a migration — is caught for free at runtime by
Rails' pending-migration / schema-consistency guard failing the migration
graders. The discriminator between asserted and exempt is always the same
determinism precondition.

## Naming

- **Reject `builder`** — collides with build systems (`make build`, `cargo
  build`, `vite build`); people would mis-file their compile step there.
- **Reject `generator`** — in a Rails shop `rails generate` is one-shot human
  scaffolding, the opposite of idempotent resync.
- **`.syrus.yml` section: `generated:`** — name it after the *artifact*, not the
  action, precisely to defeat verb-collision. A build command has no `files:` it
  claims as tool-owned, so it self-selects out. Aligns with the industry
  `// Code generated ... DO NOT EDIT.` / `linguist-generated` convention, which
  already means "produced from source, regenerated, don't hand-edit."
- **Step kind / prose term: `codegen`** — the industry word, unambiguous against
  "build."

Net vocabulary: **generated** (codegen — derived, tool-owned, hard-fail on
generator error, agent-detected) → **format** (cosmetic, in-place, safe-
autocorrect, soft-fail) → **grade** (judgment, agentic repair). Each name says
what it is *and* what it isn't.

## Proposed `.syrus.yml` schema (sketch)

```yaml
# Deterministic, correctness-load-bearing. Runs first, inside the retry loop.
generated:
  - command: "buf generate"
    sources: "proto/**/*.proto"      # input glob → rebuild gate (content hash)
    generates: "lib/proto/**/*.rb"   # output glob → formatter-exclude + fast-path veto
  - command: "bin/rails db:schema:dump"
    generates: "db/schema.rb"
    codegen_ignore: true             # committed but correctness-exempt (non-deterministic generator)

# Cosmetic, in-place, safe-autocorrect only. Self-gating by target glob.
formatters:
  - command: "bin/rubocop -a"
    files: "**/*.rb"
  - command: "npx prettier --write"
    files: "**/*.{ts,tsx,css}"

# Existing graders (checks; agentic repair). Metrics/complexity cops live here.
graders:
  - name: rspec
    command: "bin/rspec"
  - name: complexity
    command: "bin/rubocop --only Metrics"
```

## New Step kinds & pipeline placement

- New non-agentic Step kinds `codegen` and `format`, registered in `Step::Kind`.
- Initial chain becomes (illustrative):
  `prepare → base_codegen_baseline → retry_until(implement → codegen → format → graders) → summarize → test_plan → pr_open`
  where `base_codegen_baseline` captures `base_diff` for attribution (it does
  **not** file a repair Job — see above), and `codegen`/`format` run every
  repair iteration.
- Factor the changed-files computation now living in `Steps::GraderFanout`
  (landed in PR #1791) into one shared primitive consumed by graders (opt-in
  gate), formatters (self-gate), and codegen (source-gate + output-veto), rather
  than reimplementing the `git diff --name-only <base>...HEAD` logic per step.

## Preconditions & caveats

- **Reproducible generator is the precondition** for the `regen == committed`
  assertion. A non-deterministic generator makes `base_diff`/`head_diff`
  spuriously non-empty and poisons every comparison → that path must be
  `codegen_ignore: true` (validated at runtime by graders instead).
- Formatter must be **safe-autocorrect + idempotent + fail-soft + changed-files-
  scoped**.
- Nothing here is ever a hard gate on the *base's* state or on *attribution*;
  the only gates are "graders green on the healed HEAD" and "the generator could
  actually run."
- Checked-in vs gitignored generated code: the diff-guard applies only to
  checked-in outputs. Gitignored generated code is a plain build step validated
  at runtime by the graders (typecheck/rspec), with no commit to guard.

## Open questions / decisions to make

1. **Revert vs pre-heal the base** (capture-then-revert for tight diffs, vs
   capture-then-keep for dumber attribution). Lean revert unless unrelated regen
   in feature PRs is a non-issue.
2. **Source-gate implementation**: content-hash of the input set (robust) vs
   `git diff` glob-match (simpler, PR #1791-style). Lean content-hash for the
   intra-loop cost.
3. **`format` amend in feedback workflows**: confirm the `--force-with-lease`
   path is acceptable, or gate formatting to initial/retry only.
4. **Frontend parity**: prettier/eslint --fix as formatters and eslint (judgment
   rules) as graders — same `formatters:`/`graders:` split, confirm the
   changed-files scoping works for JS/TS globs (`FNM_DOTMATCH`, per PR #1791).
5. **Metrics cops baseline**: enabling `Metrics/*` as a grader on a never-linted
   repo needs a `.rubocop_todo.yml` baseline or it fails on legacy debt.

_Decided: `base_diff` never auto-files a repair Job — that's a race-condition
trap; repair-filing stays owned by the main-health path (see "Base-diff
capture")._
