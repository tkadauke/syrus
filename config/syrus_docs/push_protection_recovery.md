# GitHub push-protection recovery

GitHub push protection (secret scanning, error `GH013`) can reject any push Syrus makes. Syrus treats GitHub as the only detector: it never scans content itself.

## Classification

Every push made through `GithubAuthenticatedGit` is classified. A rejection becomes `GithubPushProtection::Rejected`, a `GitRunner::GitError` subclass carrying only sanitized findings: secret type, commit SHA, path and line. The secret value, the "allow this secret" bypass URL and the raw remote output are never logged, stored or shown. Syrus never uses a bypass.

## Mutable Job refs: bounded repair

The calling step owns recovery (`Steps::PushProtectionRecovery`): Push, PR open, source-snapshot publication and force push.

1. Record the Job/workflow lineage and the clean anchor in the `push_protection` workflow artifact. The anchor is the last commit GitHub accepted, taken from the ledger (advanced only after accepted pushes), then the live remote branch tip, then the merge-base with the default branch.
2. Bundle the rejected history outside GitHub (`$SYRUS_DATA_ROOT/push_protection/<workflow>/`) and collapse the rejected range into one commit directly atop the anchor.
3. Run a bounded agent repair: remove the secret, do not push, leave a single commit atop the anchor. Amending the tip is allowed.
4. Validate by topology: exactly the anchor as sole parent, no rejected SHA reachable, and no change to refs, remotes, `.git/config`, submodules or unrelated files. A violation resets the workspace to the candidate and retries once with precise feedback; after two attempts the step fails for operator review with the evidence kept.
5. The harness rebuilds the authoritative commit from the anchor, repaired tree and the original author/committer metadata (idempotent), pushes it, and advances the anchor only after GitHub accepts. An identical rejected SHA is never pushed again; if GitHub rejects the repaired commit too, an operator must review.

While a repair is active, ordinary checkpoint publication is suppressed so the rejected ancestry is not republished.

## Shared refs and upstream findings

Merge-train, integration, promotion and hotfix refs are quarantined, not rewritten. The sanitized evidence is routed to the member Jobs' latest workflows. A finding whose commit is the anchor or any commit outside the Job's rejected range is reported as upstream-contaminated and must be fixed by its owner.

Paths without in-place repair (stack force push, merge-train landing) fail with the `github_push_protection` problem code and the recorded evidence. Coding Mode handoff capture fails with a sanitized message.
