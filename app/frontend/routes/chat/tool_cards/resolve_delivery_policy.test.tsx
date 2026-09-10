import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import resolveDeliveryPolicyToolCard from "./resolve_delivery_policy"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "resolve_delivery_policy", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

describe("resolve_delivery_policy tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(resolveDeliveryPolicyToolCard.toolName).toBe("resolve_delivery_policy")
  })

  it("summarizes the collapsed row with the resolved track and job", () => {
    const parsedResult = { repository: "tkadauke/syrus", job_id: 325, delivery_track: "staging" }
    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Track: staging for JOB-325")
  })

  it("falls back to the default track label when unset", () => {
    const parsedResult = { repository: "tkadauke/syrus" }
    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Track: default")
  })

  it("renders approval, promotion/hotfix-sync/upstream-export toggles, and ref movement actions", () => {
    const parsedResult = {
      repository: "tkadauke/syrus",
      job_id: 325,
      delivery_track: "staging",
      job_landing_branch: "staging-branch",
      review_grade_phase: "review",
      landing_grade_phase: "landing",
      approval: { configured: true, job_approval_satisfied: false, requires_operator_approval_for_promotion: true },
      promotion: { enabled: true, mode: "auto" },
      hotfix_sync: { enabled: false, mode: null },
      upstream_export: { enabled: true, mode: "manual", after_local_approval: true },
      ref_movement_actions: {
        send_job_upstream: { enabled: true, mode: "auto", grade_phases: [ "review" ] }
      }
    }

    render(<>{resolveDeliveryPolicyToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByText("staging")).toBeInTheDocument()
    expect(screen.getByText("approval: configured")).toBeInTheDocument()
    expect(screen.getByText("job approval: pending")).toBeInTheDocument()
    expect(screen.getByText("promotion: on (auto)")).toBeInTheDocument()
    expect(screen.getByText("hotfix sync: off")).toBeInTheDocument()
    expect(screen.getByText("1 ref movement action")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    expect(resolveDeliveryPolicyToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(resolveDeliveryPolicyToolCard.renderExpanded(context({ parsedResult: "not json" }))).toBeNull()
  })
})
