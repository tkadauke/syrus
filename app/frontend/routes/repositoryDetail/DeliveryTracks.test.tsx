import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { DeliveryTracksSection } from "./DeliveryTracks"
import type { RepositoryDeliveryPayload } from "../../api/repositories"

function buildDelivery(overrides: Partial<RepositoryDeliveryPayload> = {}): RepositoryDeliveryPayload {
  return {
    tracks: [
      {
        name: "default",
        branch: "develop",
        is_default: true,
        review_grade_phase: "review",
        landing_grade_phase: "landing",
        branch_health_grade_phase: "ci",
        health: null,
        queue_length: 0,
        last_promotion: null,
        last_hotfix_sync: null
      }
    ],
    ref_movement_actions: [],
    recent_ref_movement_workflows: [],
    recent_pr_ingestions: [],
    ...overrides
  }
}

function renderSection(delivery: RepositoryDeliveryPayload) {
  render(
    <MemoryRouter>
      <DeliveryTracksSection delivery={delivery} prefix="" />
    </MemoryRouter>
  )
}

describe("DeliveryTracksSection", () => {
  it("renders the tracks table with branch and queue length", () => {
    renderSection(buildDelivery({
      tracks: [
        {
          name: "default",
          branch: "develop",
          is_default: true,
          review_grade_phase: "review",
          landing_grade_phase: "landing",
          branch_health_grade_phase: "ci",
          health: "healthy",
          queue_length: 2,
          last_promotion: { workflow_id: 5, finished_at: "2026-08-01T00:00:00Z", source_ref: "develop", target_ref: "main" },
          last_hotfix_sync: null
        },
        {
          name: "hotfix",
          branch: "release",
          is_default: false,
          review_grade_phase: "review",
          landing_grade_phase: "landing",
          branch_health_grade_phase: "ci",
          health: null,
          queue_length: 0,
          last_promotion: null,
          last_hotfix_sync: { workflow_id: 6, finished_at: "2026-08-02T00:00:00Z", source_ref: "main", target_ref: "develop" }
        }
      ]
    }))

    expect(screen.getByText("develop")).toBeInTheDocument()
    expect(screen.getByText("release")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("healthy")).toBeInTheDocument()
    expect(screen.getByText(/develop.*main/)).toBeInTheDocument()
  })

  it("renders ref-movement action availability and blocked reasons", () => {
    renderSection(buildDelivery({
      ref_movement_actions: [
        { name: "send_job_upstream", enabled: true, mode: "manual_pr", grade_phases: [], available: false, blocked_reason: "job_id is required" }
      ]
    }))

    expect(screen.getByText("send_job_upstream")).toBeInTheDocument()
    expect(screen.getByText("Blocked")).toBeInTheDocument()
    expect(screen.getByText("job_id is required")).toBeInTheDocument()
  })

  it("renders recent ref-movement workflows with a link to the job", () => {
    renderSection(buildDelivery({
      recent_ref_movement_workflows: [
        {
          id: 42,
          trigger_kind: "promotion",
          state: "succeeded",
          job_id: 7,
          job_slug: "JOB-7",
          source_ref: "develop",
          target_ref: "main",
          target_repository_slug: null,
          pr_number: null,
          pr_state: null,
          created_at: "2026-08-01T00:00:00Z",
          finished_at: "2026-08-01T01:00:00Z",
          job_path: "/jobs/7",
          workflow_path: "/jobs/7?tab=workflows#workflow-42"
        }
      ]
    }))

    const link = screen.getByRole("link", { name: "JOB-7" })
    expect(link).toHaveAttribute("href", "/jobs/7?tab=workflows#workflow-42")
    expect(screen.getByText("promotion")).toBeInTheDocument()
  })

  it("renders recent PR ingestion classifications", () => {
    renderSection(buildDelivery({
      recent_pr_ingestions: [
        {
          job_id: 9,
          job_slug: "JOB-9",
          job_path: "/jobs/9",
          pr_number: 123,
          classification: "syrus_job_export",
          ingest_mode: "attached",
          source_repo_slug: "acme/fork",
          created_at: "2026-08-01T00:00:00Z"
        }
      ]
    }))

    expect(screen.getByText("#123")).toBeInTheDocument()
    expect(screen.getByText("syrus_job_export")).toBeInTheDocument()
    expect(screen.getByText("acme/fork")).toBeInTheDocument()
  })

  it("omits table sections that have no data", () => {
    renderSection(buildDelivery({ tracks: [] }))

    expect(screen.queryByText("Track")).not.toBeInTheDocument()
    expect(screen.queryByText("Ref-movement actions")).not.toBeInTheDocument()
  })
})
