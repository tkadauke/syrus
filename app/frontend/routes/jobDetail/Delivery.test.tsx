import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { JobDetailPayload, JobPrLink } from "../../api/jobs"
import { DeliveryPanel, deliveryPanelRelevant } from "./Delivery"

function payload(overrides: Partial<JobDetailPayload> = {}): JobDetailPayload {
  return {
    job: {
      delivery_track: "default",
      delivery_target_ref: "main",
      delivery_status: "waiting_for_local_approval"
    } as JobDetailPayload["job"],
    pr_links: [],
    actions: {
      can_send_job_upstream: false,
      send_job_upstream_blocked_reason: null
    } as JobDetailPayload["actions"],
    ...overrides
  } as JobDetailPayload
}

function prLink(overrides: Partial<JobPrLink> = {}): JobPrLink {
  return {
    id: 1,
    role: "local",
    source_repository_slug: "acme/widgets",
    source_ref: "syrus/issue-1",
    target_repository_slug: "acme/widgets",
    target_ref: "main",
    pr_number: 42,
    pr_url: "https://github.com/acme/widgets/pull/42",
    pr_state: null,
    created_at: null,
    updated_at: null,
    ...overrides
  }
}

describe("deliveryPanelRelevant", () => {
  it("is false for the two default states with no track and no PR links", () => {
    expect(deliveryPanelRelevant(payload())).toBe(false)
    expect(deliveryPanelRelevant(payload({ job: { ...payload().job, delivery_status: "approved_for_local_landing" } as JobDetailPayload["job"] }))).toBe(false)
  })

  it("is true for a non-default track", () => {
    expect(deliveryPanelRelevant(payload({ job: { ...payload().job, delivery_track: "hotfix" } as JobDetailPayload["job"] }))).toBe(true)
  })

  it("is true when there are PR links", () => {
    expect(deliveryPanelRelevant(payload({ pr_links: [ prLink() ] }))).toBe(true)
  })

  it("is true when send_job_upstream is available or blocked", () => {
    expect(deliveryPanelRelevant(payload({ actions: { can_send_job_upstream: true, send_job_upstream_blocked_reason: null } as JobDetailPayload["actions"] }))).toBe(true)
    expect(deliveryPanelRelevant(payload({ actions: { can_send_job_upstream: false, send_job_upstream_blocked_reason: "job is not open" } as JobDetailPayload["actions"] }))).toBe(true)
  })

  it("is true for a notable delivery status", () => {
    expect(deliveryPanelRelevant(payload({ job: { ...payload().job, delivery_status: "delivery_needs_attention" } as JobDetailPayload["job"] }))).toBe(true)
  })
})

describe("DeliveryPanel", () => {
  it("renders the track and target ref", () => {
    render(<DeliveryPanel payload={payload({ job: { ...payload().job, delivery_track: "hotfix", delivery_target_ref: "release/1.0" } as JobDetailPayload["job"] })} />)

    expect(screen.getByText("hotfix")).toBeInTheDocument()
    expect(screen.getByText("release/1.0")).toBeInTheDocument()
  })

  it("interpolates the PR number into the waiting_for_upstream_approval status from the promotion/upstream_export PR link", () => {
    render(<DeliveryPanel payload={payload({
      job: { ...payload().job, delivery_status: "waiting_for_upstream_approval" } as JobDetailPayload["job"],
      pr_links: [ prLink({ id: 2, role: "upstream_export", pr_number: 123 }) ]
    })} />)

    expect(screen.getByText("Sent upstream: PR #123 waiting for review")).toBeInTheDocument()
  })

  it("falls back to a plain status when no PR number is recorded yet", () => {
    render(<DeliveryPanel payload={payload({ job: { ...payload().job, delivery_status: "waiting_for_upstream_approval" } as JobDetailPayload["job"] })} />)

    expect(screen.getByText("Waiting for upstream approval")).toBeInTheDocument()
  })

  it("renders PR links grouped by role", () => {
    render(<DeliveryPanel payload={payload({
      pr_links: [
        prLink({ id: 1, role: "local", pr_number: 10 }),
        prLink({ id: 2, role: "upstream_export", pr_number: 20, target_repository_slug: "acme/upstream-widgets" })
      ]
    })} />)

    expect(screen.getByText("Local")).toBeInTheDocument()
    expect(screen.getByText("Upstream export")).toBeInTheDocument()
    expect(screen.getByText("PR #10")).toBeInTheDocument()
    expect(screen.getByText("PR #20")).toBeInTheDocument()
  })

  it("shows the blocked reason for send_job_upstream when present", () => {
    render(<DeliveryPanel payload={payload({ actions: { can_send_job_upstream: false, send_job_upstream_blocked_reason: "job is not open" } as JobDetailPayload["actions"] })} />)

    expect(screen.getByText("Send upstream: job is not open")).toBeInTheDocument()
  })
})
