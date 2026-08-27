import { jsonResponse } from "../../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { DeliverySection } from "./Delivery"
import type { RepositoryDeliveryPayload, RepositoryDetailPayload } from "../../api/repositories"

const DISPATCH_PATH = "/api/v1/app/repositories/1/dispatch_ref_movement_action"

function buildDelivery(overrides: Partial<RepositoryDeliveryPayload> = {}): RepositoryDeliveryPayload {
  return {
    tracks: [
      {
        name: "default",
        default: true,
        branch: "develop",
        review_grade_phase: "review",
        landing_grade_phase: "landing",
        branch_health_grade_phase: "ci",
        health: "healthy",
        landing_queue_count: 2,
        queue_path: null,
        last_promotion_or_sync_at: null
      }
    ],
    promotion: { enabled: false, mode: "auto_pr", source_branch: "develop", target_branch: "main", requires_operator_approval: false },
    hotfix_sync: { enabled: false, mode: "auto", source_branch: "main", target_branch: "develop" },
    upstream_export: { enabled: false, mode: "none", after_local_approval: false, target_branch: null },
    ref_movement_actions: [],
    recent_ref_movement_actions: [],
    recent_workflows: [],
    recent_pr_ingestions: [],
    paths: { app_dispatch_ref_movement_action_repository_path: DISPATCH_PATH },
    ...overrides
  }
}

function renderSection(delivery = buildDelivery()) {
  const queryKey = ["repositories", "1", "detail", ""] as const
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <DeliverySection delivery={delivery} onNotice={vi.fn()} page={1} prefix="" queryKey={queryKey} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("DeliverySection tracks table", () => {
  it("renders each track's branch, grade phases, health, and queue count", () => {
    renderSection()

    expect(screen.getByText("develop")).toBeInTheDocument()
    expect(screen.getByText("review / landing / ci")).toBeInTheDocument()
    expect(screen.getByText("healthy")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
  })

  it("links the queue count when a queue_path is present", () => {
    const delivery = buildDelivery()
    delivery.tracks[0].queue_path = "/dashboard/jobs?q=abc123"
    renderSection(delivery)

    const link = screen.getByRole("link", { name: "2" })
    expect(link).toHaveAttribute("href", "/dashboard/jobs?q=abc123")
  })
})

describe("DeliverySection ref-movement actions", () => {
  it("shows no-actions message when none are configured", () => {
    renderSection()

    expect(screen.getByText("No ref-movement actions configured in delivery.ref_movement_actions.")).toBeInTheDocument()
  })

  it("renders a blocked action with its reason and a disabled dispatch button", () => {
    const delivery = buildDelivery({
      ref_movement_actions: [
        { name: "send_job_upstream", enabled: true, mode: "manual_pr", grade_phases: [], available: false, blocked_reason: "job is required for send_job_upstream" }
      ]
    })
    renderSection(delivery)

    expect(screen.getByText("Blocked")).toBeInTheDocument()
    expect(screen.getByText("job is required for send_job_upstream")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Dispatch" })).toBeDisabled()
  })

  it("dispatches an available action and applies the returned payload", async () => {
    const delivery = buildDelivery({
      ref_movement_actions: [
        { name: "submit_branch_upstream", enabled: true, mode: "manual_pr", grade_phases: [], available: true, blocked_reason: null }
      ]
    })
    const updated: RepositoryDetailPayload = { message: "Dispatched submit_branch_upstream." } as RepositoryDetailPayload
    const fetchSpy = vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(updated))
    renderSection(delivery)

    const dispatchButton = screen.getByRole("button", { name: "Dispatch" })
    expect(dispatchButton).not.toBeDisabled()
    fireEvent.click(dispatchButton)

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        DISPATCH_PATH,
        expect.objectContaining({ method: "POST" })
      )
    })
  })
})

describe("DeliverySection history sections", () => {
  it("renders recent ref-movement actions, workflows, and PR ingestions", () => {
    const delivery = buildDelivery({
      recent_ref_movement_actions: [
        {
          id: 1, action_name: "submit_branch_upstream", state: "dispatched", blocked_reason: null,
          requested_by: "ada@example.com", source_kind: "branch", source_ref: "develop",
          target_kind: "upstream_intake", target_ref: "main", target_repository_slug: "upstream/widgets",
          target_inferred: false, job: { id: 9, slug: "JOB-9", job_path: "/jobs/9" }, workflow_path: "/jobs/9?tab=workflows#workflow-1",
          created_at: "2026-01-01T00:00:00Z"
        }
      ],
      recent_workflows: [
        {
          id: 5, trigger_kind: "promotion", trigger_kind_label: "Promotion", state: "succeeded",
          job: { id: 12, slug: "JOB-12", job_path: "/jobs/12" }, source_ref: "develop", target_ref: "main",
          target_repository_slug: null, created_at: "2026-01-02T00:00:00Z", finished_at: "2026-01-02T01:00:00Z"
        }
      ],
      recent_pr_ingestions: [
        {
          job: { id: 20, slug: "JOB-20", job_path: "/jobs/20" }, pr_number: 42, external_pr_url: "https://github.com/acme/widgets/pull/42",
          external_pr_author: "casey", provenance: "syrus_job_export", ingest_mode: "attached", source_repo_slug: "casey/widgets",
          created_at: "2026-01-03T00:00:00Z"
        }
      ]
    })
    renderSection(delivery)

    expect(screen.getByText("submit_branch_upstream")).toBeInTheDocument()
    expect(screen.getAllByText("develop → main").length).toBe(2)
    expect(screen.getByText("Promotion")).toBeInTheDocument()
    expect(screen.getByText("PR #42")).toBeInTheDocument()
    expect(screen.getByText("syrus job export")).toBeInTheDocument()
    expect(screen.getAllByText("JOB-9").length + screen.getAllByText("JOB-12").length + screen.getAllByText("JOB-20").length).toBeGreaterThan(0)
  })
})
