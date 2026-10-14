import { QueryClient } from "@tanstack/react-query"
import { describe, expect, it } from "vitest"
import { invalidateJobSurfaces } from "./jobQueryInvalidation"

describe("invalidateJobSurfaces", () => {
  it("invalidates dashboard and matching job caches without invalidating other jobs", async () => {
    const queryClient = new QueryClient()
    const dashboardKey = ["dashboard", "rows", "?state=running"] as const
    const previewKey = ["jobs", "7"] as const
    const detailKey = ["jobs", "7", "detail", ""] as const
    const workflowsKey = ["jobs", "7", "workflows", ""] as const
    const otherJobKey = ["jobs", "8"] as const

    for (const queryKey of [dashboardKey, previewKey, detailKey, workflowsKey, otherJobKey]) {
      queryClient.setQueryData(queryKey, {})
    }

    invalidateJobSurfaces(queryClient, 7)
    await Promise.resolve()

    expect(queryClient.getQueryState(dashboardKey)?.isInvalidated).toBe(true)
    expect(queryClient.getQueryState(previewKey)?.isInvalidated).toBe(true)
    expect(queryClient.getQueryState(detailKey)?.isInvalidated).toBe(true)
    expect(queryClient.getQueryState(workflowsKey)?.isInvalidated).toBe(true)
    expect(queryClient.getQueryState(otherJobKey)?.isInvalidated).toBe(false)
  })
})
