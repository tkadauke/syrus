import { describe, expect, it, afterEach } from "vitest"
import {
  createDashboardJobNavigationContext,
  createEpicJobNavigationContext,
  jobNavigationHref,
  readJobNavigationContext,
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

  it("carries Job Detail tab state but drops source-specific diff params", () => {
    expect(jobNavigationHref("/jobs/3", "/app-shell", "nav-token", "?tab=source&diff_base=aaa&diff_head=bbb")).toBe("/app-shell/jobs/3?tab=source&job_nav=nav-token")
  })
})

function dashboardJob(id: number) {
  return {
    id,
    title: `Job ${id}`,
    state: "running",
    summary_state: "running",
    repository: { slug: "acme/widgets" },
    paths: { job_path: `/jobs/${id}` }
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
