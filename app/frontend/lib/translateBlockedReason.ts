import type { TFunction } from "i18next"

const STATIC_REASONS: Record<string, string> = {
  "landing paused": "common:blocked_reasons.landing_paused",
  "landing paused: main branch broken": "common:blocked_reasons.landing_paused_main_broken",
  "repository archived": "common:blocked_reasons.repository_archived",
  "waiting for Epic merge-train": "common:blocked_reasons.waiting_epic_merge_train",
  "epic reconciliation pending": "common:blocked_reasons.legacy_epic_reconciliation_pending",
  "auto-merge not enabled for repository": "common:blocked_reasons.auto_merge_not_enabled",
  "review requested changes": "common:blocked_reasons.review_requested_changes",
  "missing pull request": "common:blocked_reasons.missing_pull_request",
  "active workflow": "common:blocked_reasons.active_workflow",
  "waiting for Epic to release": "common:blocked_reasons.waiting_epic_release",
  "waiting for epic siblings to be approved": "common:blocked_reasons.waiting_epic_siblings",
  "waiting for GitHub mergeability": "common:blocked_reasons.waiting_github_mergeability",
  "waiting for GitHub mergeability after no-op rebase": "common:blocked_reasons.waiting_github_mergeability_noop",
  "rebase cap reached; manual rebase or PR update required": "common:blocked_reasons.rebase_cap_reached",
  "pr_not_mergeable": "common:blocked_reasons.pr_not_mergeable",
}

const DYNAMIC_PATTERNS: Array<{
  pattern: RegExp
  key: string
  params: (match: RegExpMatchArray) => Record<string, string>
}> = [
  {
    pattern: /^ci_failure workflow in progress on (.+)$/,
    key: "common:blocked_reasons.ci_failure_in_progress",
    params: (m) => ({ slug: m[1] }),
  },
  {
    pattern: /^PR checks failing on (.+)$/,
    key: "common:blocked_reasons.pr_checks_failing",
    params: (m) => ({ slug: m[1] }),
  },
  {
    pattern: /^PR checks pending on (.+)$/,
    key: "common:blocked_reasons.pr_checks_pending",
    params: (m) => ({ slug: m[1] }),
  },
  {
    pattern: /^waiting for (.+) to merge$/,
    key: "common:blocked_reasons.waiting_to_merge",
    params: (m) => ({ slug: m[1] }),
  },
  {
    pattern: /^waiting for Epic #(\d+) to complete$/,
    key: "common:blocked_reasons.waiting_epic_to_complete",
    params: (m) => ({ number: m[1] }),
  },
]

export function translateBlockedReason(reason: string | null | undefined, t: TFunction): string {
  if (!reason) return ""

  const staticKey = STATIC_REASONS[reason]
  if (staticKey) return t(staticKey)

  for (const { pattern, key, params } of DYNAMIC_PATTERNS) {
    const match = reason.match(pattern)
    if (match) return t(key, params(match))
  }

  return reason
}
