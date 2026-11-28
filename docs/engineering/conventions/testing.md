# Testing and workspace safety

Use these rules when writing tests, reviewing diffs, and managing test workspaces.

- **Three-dot diffs only** — `git diff <base>...HEAD`, never two-dot.
  Lesson learned the hard way (commit `67b2bf9`).
- **Clones live outside the repo** — under `$SYRUS_DATA_ROOT` (default
  `~/.syrus`). The agent's `chdir` MUST NOT be inside the operator's
  checkout. (Lesson from commit `ced3a65`.)
- **Tests** — RSpec, no FactoryBot. Lightweight `Factories` module in
  `spec/support/`. WebMock + VCR for GitHub. The agent runner is stubbed
  via `RunJob.agent_runner` and `PrSummarizer.runner` test seams; never
  shell out to real `claude` from tests.
- **Failure decisions replay against production** — changes to
  `RunFailureClassifier`, `Problem::Kind` retryability, or AutoRetryJob's
  retryability recheck (`AutoRetryJob.retryability_recheck_skips?`) are
  checked by `spec/lib/failure_corpus/failure_corpus_replay_spec.rb`, which
  replays a sanitized corpus of real production failures
  (`spec/fixtures/failure_corpus/cases.jsonl`) and fails on any retryability
  or recheck flip that `spec/fixtures/failure_corpus/allowlist.yml` does not
  acknowledge with a status and reason. `RAILS_ENV=test bin/rails
  failure_corpus:replay` prints the full drift report. Refresh the corpus
  with `bin/export-failure-corpus` (read-only against production; redaction
  and a verdict-fidelity check run on the instance), then re-run the replay
  and prune or re-acknowledge the allowlist.
