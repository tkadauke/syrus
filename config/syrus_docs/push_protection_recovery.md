# GitHub push-protection recovery

GitHub push protection can reject a Syrus push. Syrus treats GitHub as the
detector and exposes only sanitized findings: secret type, commit, path, and
line. Secret values, bypass links, and raw remote output are never stored or
shown, and Syrus never uses a bypass.

## Mutable Job refs: bounded repair

For a mutable Job branch, Syrus keeps the rejected history outside GitHub,
collapses the rejected range onto the last accepted anchor, and gives an agent
at most two attempts to remove the secret without pushing. It validates that
the repaired history has the required topology and did not alter unrelated
files or Git configuration. Syrus then rebuilds and pushes the authoritative
commit. It never retries the same rejected commit; another rejection requires
operator review.

## Shared refs and upstream findings

Merge-train, integration, promotion, and hotfix refs are quarantined instead
of rewritten. Findings outside the Job's rejected range are reported as
upstream contamination for the owning work to fix. Paths that cannot safely
repair in place fail with a push-protection problem and sanitized evidence.
