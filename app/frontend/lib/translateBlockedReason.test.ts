import { describe, expect, it } from "vitest"
import { translateBlockedReason } from "./translateBlockedReason"
import type { TFunction } from "i18next"

// Mock t returns key + params so we can verify both key selection and interpolation
const mockT = ((key: string, params?: Record<string, string>) => {
  if (!params || Object.keys(params).length === 0) return key
  const paramStr = Object.entries(params)
    .map(([k, v]) => `${k}=${v}`)
    .join(",")
  return `${key}(${paramStr})`
}) as unknown as TFunction

describe("translateBlockedReason", () => {
  it("returns empty string for null/undefined/empty", () => {
    expect(translateBlockedReason(null, mockT)).toBe("")
    expect(translateBlockedReason(undefined, mockT)).toBe("")
    expect(translateBlockedReason("", mockT)).toBe("")
  })

  it("translates static reasons to their i18n keys", () => {
    expect(translateBlockedReason("landing paused", mockT)).toBe("common:blocked_reasons.landing_paused")
    expect(translateBlockedReason("landing paused: main branch broken", mockT)).toBe("common:blocked_reasons.landing_paused_main_broken")
    expect(translateBlockedReason("repository archived", mockT)).toBe("common:blocked_reasons.repository_archived")
    expect(translateBlockedReason("waiting for Epic merge-train", mockT)).toBe("common:blocked_reasons.waiting_epic_merge_train")
    expect(translateBlockedReason("auto-merge not enabled for repository", mockT)).toBe("common:blocked_reasons.auto_merge_not_enabled")
    expect(translateBlockedReason("review requested changes", mockT)).toBe("common:blocked_reasons.review_requested_changes")
    expect(translateBlockedReason("missing pull request", mockT)).toBe("common:blocked_reasons.missing_pull_request")
    expect(translateBlockedReason("active workflow", mockT)).toBe("common:blocked_reasons.active_workflow")
    expect(translateBlockedReason("waiting for Epic to release", mockT)).toBe("common:blocked_reasons.waiting_epic_release")
    expect(translateBlockedReason("waiting for epic siblings to be approved", mockT)).toBe("common:blocked_reasons.waiting_epic_siblings")
    expect(translateBlockedReason("waiting for GitHub mergeability", mockT)).toBe("common:blocked_reasons.waiting_github_mergeability")
    expect(translateBlockedReason("waiting for GitHub mergeability after no-op rebase", mockT)).toBe("common:blocked_reasons.waiting_github_mergeability_noop")
    expect(translateBlockedReason("rebase cap reached; manual rebase or PR update required", mockT)).toBe("common:blocked_reasons.rebase_cap_reached")
    expect(translateBlockedReason("pr_not_mergeable", mockT)).toBe("common:blocked_reasons.pr_not_mergeable")
  })

  it("translates dynamic reasons with slug interpolation", () => {
    expect(translateBlockedReason("ci_failure workflow in progress on JOB-123", mockT))
      .toBe("common:blocked_reasons.ci_failure_in_progress(slug=JOB-123)")
    expect(translateBlockedReason("PR checks failing on JOB-456", mockT))
      .toBe("common:blocked_reasons.pr_checks_failing(slug=JOB-456)")
    expect(translateBlockedReason("PR checks pending on JOB-789", mockT))
      .toBe("common:blocked_reasons.pr_checks_pending(slug=JOB-789)")
    expect(translateBlockedReason("waiting for JOB-42 to merge", mockT))
      .toBe("common:blocked_reasons.waiting_to_merge(slug=JOB-42)")
    expect(translateBlockedReason("waiting for some-pending-slug to merge", mockT))
      .toBe("common:blocked_reasons.waiting_to_merge(slug=some-pending-slug)")
    expect(translateBlockedReason("waiting for Epic #7 to complete", mockT))
      .toBe("common:blocked_reasons.waiting_epic_to_complete(number=7)")
  })

  it("returns unknown reasons unchanged as fallback", () => {
    expect(translateBlockedReason("some unknown reason", mockT)).toBe("some unknown reason")
    expect(translateBlockedReason("PR checks failing", mockT)).toBe("PR checks failing")
  })
})
