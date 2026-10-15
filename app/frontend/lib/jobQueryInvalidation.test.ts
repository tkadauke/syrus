import { QueryClient } from "@tanstack/react-query"
import { describe, expect, it } from "vitest"
import { invalidateJobSurfaces } from "./jobQueryInvalidation"

describe("invalidateJobSurfaces", () => {
  it("invalidates dashboard and the exact job preview without fanning out to expensive job caches", async () => {
    const queryClient = new QueryClient()
    const dashboardKey = ["dashboard", "rows", "?state=running"] as const
    const previewKey = ["jobs", "7"] as const
    const detailKey = ["jobs", "7", "detail", ""] as const
    const workflowsKey = ["jobs", "7", "workflows", ""] as const
    const sourceKey = ["jobs", "7", "source", ""] as const
    const sourceDiffKey = ["jobs", "7", "source_diff", ""] as const
    const reviewCommentsKey = ["jobs", "7", "diff_review_comments", "job_source_diff", ""] as const
    const otherJobKey = ["jobs", "8"] as const

    for (const queryKey of [dashboardKey, previewKey, detailKey, workflowsKey, sourceKey, sourceDiffKey, reviewCommentsKey, otherJobKey]) {
      queryClient.setQueryData(queryKey, {})
    }

    invalidateJobSurfaces(queryClient, 7)
    await Promise.resolve()

    expect(queryClient.getQueryState(dashboardKey)?.isInvalidated).toBe(true)
    expect(queryClient.getQueryState(previewKey)?.isInvalidated).toBe(true)
    expect(queryClient.getQueryState(detailKey)?.isInvalidated).toBe(false)
    expect(queryClient.getQueryState(workflowsKey)?.isInvalidated).toBe(false)
    expect(queryClient.getQueryState(sourceKey)?.isInvalidated).toBe(false)
    expect(queryClient.getQueryState(sourceDiffKey)?.isInvalidated).toBe(false)
    expect(queryClient.getQueryState(reviewCommentsKey)?.isInvalidated).toBe(false)
    expect(queryClient.getQueryState(otherJobKey)?.isInvalidated).toBe(false)
  })
})
