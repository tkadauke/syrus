import { describe, expect, it, afterEach } from "vitest"
import {
  createDashboardJobNavigationContext,
  createEpicJobNavigationContext,
  jobNavigationHref,
  patchJobNavigationContextItem,
  readJobNavigationContext,
  recordJobNavigationKnownState,
  storeJobNavigationContext
} from "./jobNavigationContext"

describe("job navigation context", () => {
  afterEach(() => window.sessionStorage.clear())

  it("stores and reads an activated per-tab context by token", () => {
    const context = createDashboardJobNavigationContext({
      currentJobId: 2,
      label: "Dashboard",
      items: [
        dashboardJob(1),
        dashboardJob(2),
        dashboardJob(3)
      ],
      sourcePath: "/dashboard"
    })

    const token = storeJobNavigationContext(context)

    expect(token).toBe(context?.token)
    expect(readJobNavigationContext(token)?.items.map((item) => item.id)).toEqual([1, 2, 3])
    expect(readJobNavigationContext("missing")).toBeNull()
  })

  it("does not create a navigation context for a single listed job", () => {
    expect(createDashboardJobNavigationContext({
      currentJobId: 1,
      label: "Dashboard",
      items: [dashboardJob(1)]
    })).toBeNull()
  })

  it("caps large dashboard snapshots to a window around the clicked job", () => {
    const context = createDashboardJobNavigationContext({
      currentJobId: 45,
      label: "Dashboard",
      items: Array.from({ length: 100 }, (_value, index) => dashboardJob(index + 1))
    })

    expect(context?.items).toHaveLength(50)
    expect(context?.items[0].id).toBe(21)
    expect(context?.items[24].id).toBe(45)
    expect(context?.items[49].id).toBe(70)
  })

  it("carries the owner badge and updated_at only when the repository has multiple members", () => {
    const context = createDashboardJobNavigationContext({
      currentJobId: 1,
      label: "Dashboard",
      items: [
        dashboardJob(1, { repository: { slug: "acme/widgets", multiple_members: true }, owner_badge: { label: "jane@example.com", kind: "other_user" }, updated_at: "2026-09-11T11:00:00Z" }),
        dashboardJob(2, { repository: { slug: "acme/widgets", multiple_members: false }, owner_badge: { label: "jane@example.com", kind: "other_user" }, updated_at: "2026-09-11T11:00:00Z" })
      ]
    })

    expect(context?.items[0].ownerBadge).toEqual({ label: "jane@example.com", kind: "other_user" })
    expect(context?.items[0].updatedAt).toBe("2026-09-11T11:00:00Z")
    expect(context?.items[1].ownerBadge).toBeNull()
    expect(context?.items[1].updatedAt).toBe("2026-09-11T11:00:00Z")
  })

  it("captures Epic jobs in their supplied linear order", () => {
    const context = createEpicJobNavigationContext({
      currentJobId: 12,
      label: "Epic Jobs",
      items: [
        epicJob(11),
        epicJob(12),
        epicJob(13)
      ],
      epicId: 5
    })

    expect(context?.kind).toBe("epic")
    expect(context?.items.map((item) => item.slug)).toEqual(["JOB-11", "JOB-12", "JOB-13"])
  })

  it("patches a stored context's item state and persists the change", () => {
    const context = createDashboardJobNavigationContext({
      currentJobId: 2,
      label: "Dashboard",
      items: [dashboardJob(1), dashboardJob(2), dashboardJob(3)]
    })
    const token = storeJobNavigationContext(context)

    const patched = patchJobNavigationContextItem(readJobNavigationContext(token), 2, "implemented", "2026-09-17T12:00:00Z")
    expect(patched?.items.find((item) => item.id === 2)).toMatchObject({ state: "implemented", updatedAt: "2026-09-17T12:00:00Z" })
    storeJobNavigationContext(patched)

    expect(readJobNavigationContext(token)?.items.find((item) => item.id === 2)).toMatchObject({ state: "implemented", updatedAt: "2026-09-17T12:00:00Z" })
    // Unrelated items are untouched, and the same object is returned when nothing changes.
    expect(readJobNavigationContext(token)?.items.find((item) => item.id === 1)).toMatchObject({ state: "running" })
    const unchanged = readJobNavigationContext(token)
    expect(patchJobNavigationContextItem(unchanged, 2, "implemented", "2026-09-17T12:00:00Z")).toBe(unchanged)
  })

  it("returns null unchanged when patching a null context", () => {
    expect(patchJobNavigationContextItem(null, 1, "implemented")).toBeNull()
  })

  it("overlays a job's live recorded state onto every stored context that references it", () => {
    const firstContext = createDashboardJobNavigationContext({
      currentJobId: 1,
      label: "Dashboard",
      items: [dashboardJob(1), dashboardJob(2)]
    })
    const secondContext = createEpicJobNavigationContext({
      currentJobId: 2,
      label: "Epic Jobs",
      items: [epicJob(2), epicJob(3)]
    })
    const firstToken = storeJobNavigationContext(firstContext)
    const secondToken = storeJobNavigationContext(secondContext)

    recordJobNavigationKnownState(2, "approved", "2026-09-17T13:00:00Z")

    expect(readJobNavigationContext(firstToken)?.items.find((item) => item.id === 2)).toMatchObject({ state: "approved", updatedAt: "2026-09-17T13:00:00Z" })
    expect(readJobNavigationContext(secondToken)?.items.find((item) => item.id === 2)).toMatchObject({ state: "approved", updatedAt: "2026-09-17T13:00:00Z" })
    // Job 1 was never recorded, so its snapshot state is untouched.
    expect(readJobNavigationContext(firstToken)?.items.find((item) => item.id === 1)).toMatchObject({ state: "running" })
  })

  it("carries Job Detail tab state but drops source-specific diff params", () => {
    expect(jobNavigationHref("/jobs/3", "/app-shell", "nav-token", "?tab=source&diff_base=aaa&diff_head=bbb")).toBe("/app-shell/jobs/3?tab=source&job_nav=nav-token")
  })

  it("preserves the path-based source tab while dropping source-specific diff params", () => {
    expect(jobNavigationHref("/jobs/3", "/app-shell", "nav-token", "?diff_base=aaa&diff_head=bbb", "/app-shell/jobs/2/source")).toBe("/app-shell/jobs/3/source?job_nav=nav-token")
  })
})

function dashboardJob(id: number, overrides: Record<string, unknown> = {}) {
  return {
    id,
    title: `Job ${id}`,
    state: "running",
    summary_state: "running",
    repository: { slug: "acme/widgets" },
    paths: { job_path: `/jobs/${id}` },
    ...overrides
  }
}

function epicJob(id: number) {
  return {
    id,
    slug: `JOB-${id}`,
    title: `Job ${id}`,
    path: `/jobs/${id}`,
    state: "implemented",
    repository_slug: "acme/widgets"
  }
}
