import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import type { JobDetailPayload } from "../../api/jobs"
import { jobDetailPayload } from "../../test/app/jobPayloads"
import { RecoveryCard } from "./RecoveryCard"

function command() {
  return { mutate: vi.fn(), isPending: false } as unknown as Parameters<typeof RecoveryCard>[0]["command"]
}

function payload(actions: Partial<JobDetailPayload["actions"]>, job: Record<string, unknown> = {}) {
  const base = jobDetailPayload() as JobDetailPayload
  return { ...base, job: { ...base.job, state: "failed" as const, ...job }, actions: { ...base.actions, can_write: true, retry_agent_options: [], ...actions } }
}

describe("RecoveryCard", () => {
  it("explains measured and excluded failures before execution metadata", () => {
    render(
      <RecoveryCard
        command={command()}
        payload={payload({
          recovery_decision: {
            kind: "grader_loop_no_progress",
            recommended_action: "repair_with_guidance",
            mode: "failed_step",
            explanation: "None of the previously failing test identities passed after repair.",
            evidence: {
              source_workflow_id: 9,
              measured_failure_identities: ["frontend\0renders recovery"],
              rounds: [{ grader_results: [{ name: "worker timeout", classification: "infrastructure" }] }]
            }
          },
          retry_failed_step_action: { key: "retry_failed_step", label: "Retry", path: "/retry" }
        })}
      />
    )
    expect(screen.getByText("None of the previously failing test identities passed after repair.")).toBeVisible()
    expect(screen.getByText("frontend — renders recovery")).toBeVisible()
    expect(screen.getByText("worker timeout")).toBeVisible()
    expect(screen.getByText("Workflow 9")).not.toBeVisible()
  })

  it("requires and prefills guidance for no-progress repair", () => {
    render(
      <RecoveryCard
        command={command()}
        payload={payload({
          recovery_decision: {
            kind: "grader_loop_no_progress",
            recommended_action: "repair_with_guidance",
            mode: "failed_step",
            explanation: "No progress.",
            guidance: "Inspect the persistent assertion.",
            evidence: { measured_failure_identities: ["frontend\0assertion"] }
          },
          retry_failed_step_action: { key: "retry_failed_step", label: "Retry", path: "/retry" }
        })}
      />
    )
    fireEvent.click(screen.getByRole("button", { name: "Repair with guidance" }))
    expect((screen.getByLabelText("Feedback") as HTMLTextAreaElement).value).toContain("Inspect the persistent assertion.")
    expect(screen.getByLabelText("Feedback")).toBeRequired()
  })

  it("labels infrastructure-only recovery as an unchanged check rerun", () => {
    render(
      <RecoveryCard
        command={command()}
        payload={payload({
          recovery_decision: {
            kind: "infrastructure_only",
            recommended_action: "rerun_unchanged",
            mode: "failed_step",
            explanation: "No trustworthy verdict.",
            evidence: {}
          },
          retry_failed_step_action: { key: "retry_failed_step", label: "Retry", path: "/retry" }
        })}
      />
    )
    expect(screen.getByRole("button", { name: "Rerun check" })).toBeEnabled()
  })

  it("shows provenance and disables actions without permission", () => {
    render(
      <RecoveryCard
        command={command()}
        payload={payload({
          can_write: false,
          recovery_decision: {
            kind: "measured_failure",
            recommended_action: "repair_with_guidance",
            mode: "failed_step",
            explanation: "A check failed.",
            evidence: {}
          },
          recovery_timeline: [{ id: 1, action: "retry_failed_step", actor: "Operator", actor_type: "operator", origin: "job_page" }]
        })}
      />
    )
    expect(screen.getByText(/Operator · job page/)).toBeVisible()
    expect(screen.getByRole("button", { name: "Repair with guidance" })).toBeDisabled()
    expect(screen.getByText(/do not have permission/)).toBeVisible()
  })

  it("uses the restart action when the workspace is unavailable", () => {
    render(
      <RecoveryCard
        command={command()}
        payload={payload({
          recovery_decision: {
            kind: "workspace_unavailable",
            recommended_action: "fresh_implementation",
            mode: "implementation",
            explanation: "Workspace unavailable.",
            evidence: {}
          },
          retry_implementation_action: { key: "retry_implementation", label: "Retry", path: "/restart" }
        })}
      />
    )
    expect(screen.getByRole("button", { name: "Restart implementation" })).toBeEnabled()
  })
})
