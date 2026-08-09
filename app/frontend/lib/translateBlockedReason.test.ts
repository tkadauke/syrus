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
  })

  it("translates structured reasons by key", () => {
    expect(translateBlockedReason({ key: "landing_paused" }, mockT)).toBe("common:blocked_reasons.landing_paused")
    expect(translateBlockedReason({ key: "landing_paused_main_broken" }, mockT)).toBe("common:blocked_reasons.landing_paused_main_broken")
    expect(translateBlockedReason({ key: "repository_archived" }, mockT)).toBe("common:blocked_reasons.repository_archived")
    expect(translateBlockedReason({ key: "waiting_epic_merge_train" }, mockT)).toBe("common:blocked_reasons.waiting_epic_merge_train")
    expect(translateBlockedReason({ key: "auto_merge_not_enabled" }, mockT)).toBe("common:blocked_reasons.auto_merge_not_enabled")
    expect(translateBlockedReason({ key: "review_requested_changes" }, mockT)).toBe("common:blocked_reasons.review_requested_changes")
    expect(translateBlockedReason({ key: "missing_pull_request" }, mockT)).toBe("common:blocked_reasons.missing_pull_request")
    expect(translateBlockedReason({ key: "active_workflow" }, mockT)).toBe("common:blocked_reasons.active_workflow")
    expect(translateBlockedReason({ key: "waiting_epic_release" }, mockT)).toBe("common:blocked_reasons.waiting_epic_release")
    expect(translateBlockedReason({ key: "waiting_epic_siblings" }, mockT)).toBe("common:blocked_reasons.waiting_epic_siblings")
    expect(translateBlockedReason({ key: "waiting_github_mergeability" }, mockT)).toBe("common:blocked_reasons.waiting_github_mergeability")
    expect(translateBlockedReason({ key: "waiting_github_mergeability_noop" }, mockT)).toBe("common:blocked_reasons.waiting_github_mergeability_noop")
    expect(translateBlockedReason({ key: "landing_start_blocked_retrying" }, mockT)).toBe("common:blocked_reasons.landing_start_blocked_retrying")
    expect(translateBlockedReason({ key: "rebase_cap_reached" }, mockT)).toBe("common:blocked_reasons.rebase_cap_reached")
    expect(translateBlockedReason({ key: "urgent_job_active" }, mockT)).toBe("common:blocked_reasons.urgent_job_active")
  })

  it("translates structured reasons with params", () => {
    expect(translateBlockedReason({ key: "ci_failure_in_progress", params: { slug: "JOB-123" } }, mockT))
      .toBe("common:blocked_reasons.ci_failure_in_progress(slug=JOB-123)")
    expect(translateBlockedReason({ key: "ci_repair_no_effective_change", params: { slug: "JOB-123" } }, mockT))
      .toBe("common:blocked_reasons.ci_repair_no_effective_change(slug=JOB-123)")
    expect(translateBlockedReason({ key: "pr_checks_failing", params: { slug: "JOB-456" } }, mockT))
      .toBe("common:blocked_reasons.pr_checks_failing(slug=JOB-456)")
    expect(translateBlockedReason({ key: "pr_checks_pending", params: { slug: "JOB-789" } }, mockT))
      .toBe("common:blocked_reasons.pr_checks_pending(slug=JOB-789)")
    expect(translateBlockedReason({ key: "waiting_to_merge", params: { slug: "JOB-42" } }, mockT))
      .toBe("common:blocked_reasons.waiting_to_merge(slug=JOB-42)")
    expect(translateBlockedReason({ key: "waiting_epic_to_complete", params: { number: 7 } }, mockT))
      .toBe("common:blocked_reasons.waiting_epic_to_complete(number=7)")
  })

  it("passes through raw strings as legacy fallback", () => {
    expect(translateBlockedReason("some legacy string reason", mockT)).toBe("some legacy string reason")
    expect(translateBlockedReason("landing paused", mockT)).toBe("landing paused")
  })
})
