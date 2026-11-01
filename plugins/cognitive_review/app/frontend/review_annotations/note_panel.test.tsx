import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import CognitiveReviewNotePanel from "./note_panel"

const apiMocks = vi.hoisted(() => ({ acknowledge: vi.fn() }))

vi.mock("../api/cognitiveReviewNotes", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../api/cognitiveReviewNotes")>()),
  acknowledgeCognitiveReviewNote: apiMocks.acknowledge
}))

const openNote = {
  end_line: 4,
  job_id: 1,
  note_id: 7,
  open_unhandled: true,
  path: "app/models/job.rb",
  side: "new" as const,
  start_line: 4,
  title: "Review this change"
}

const handledNote = { ...openNote, handled: true, open_unhandled: false, state: "acknowledged" }
const historicalKey = ["jobs", "1", "diff_review_versions", 23] as const
const otherJobKey = ["jobs", "2", "diff_review_versions", 41] as const

function HistoricalNote({ fetchVersion }: { fetchVersion: () => Promise<typeof handledNote> }) {
  const version = useQuery({
    initialData: openNote,
    queryFn: fetchVersion,
    queryKey: historicalKey,
    staleTime: Infinity
  })

  return <CognitiveReviewNotePanel item={{ component: "cognitive_review/note_panel", props: version.data }} surface="sidebar" />
}

describe("CognitiveReviewNotePanel query reconciliation", () => {
  it("keeps acknowledgement hidden after refreshing only this job's historical versions", async () => {
    apiMocks.acknowledge.mockResolvedValue({})
    const fetchVersion = vi.fn().mockResolvedValue(handledNote)
    const otherJobFetch = vi.fn().mockResolvedValue(openNote)
    const client = new QueryClient({ defaultOptions: { mutations: { retry: false }, queries: { retry: false } } })
    client.setQueryData(otherJobKey, openNote)
    client.setQueryDefaults(otherJobKey, { queryFn: otherJobFetch, staleTime: Infinity })
    const invalidateQueries = vi.spyOn(client, "invalidateQueries")

    render(
      <QueryClientProvider client={client}>
        <HistoricalNote fetchVersion={fetchVersion} />
      </QueryClientProvider>
    )

    fireEvent.click(screen.getByRole("button", { name: "Acknowledge" }))

    await waitFor(() => expect(apiMocks.acknowledge).toHaveBeenCalledWith(1, 7))
    await waitFor(() => expect(fetchVersion).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.queryByRole("button", { name: "Acknowledge" })).not.toBeInTheDocument())
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ["jobs", "1", "diff_review_versions"] })
    expect(otherJobFetch).not.toHaveBeenCalled()
    expect(client.getQueryState(otherJobKey)?.isInvalidated).toBe(false)
  })
})
