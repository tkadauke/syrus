import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { JobQuestionPanel } from "./JobDetail"

describe("JobQuestionPanel", () => {
  afterEach(() => vi.restoreAllMocks())

  it("keeps retry out of the answer actions and confirms its recovery consequences", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      new Response(
        JSON.stringify({ questions: [{ id: 7, questions: [{ question: "Which path?", options: ["Safe"], multiple: false }], app_answer_path: "/answer" }] }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" }
        }
      )
    )
    const mutate = vi.fn()
    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <JobQuestionPanel
            command={{ mutate, isPending: false } as never}
            job={{ id: 3, has_open_agent_question: true, question_eagerness: "collaborative", question_eagerness_source: "repository" } as never}
            onNotice={() => {}}
            paths={{ app_run_again_path: "/retry", app_cancel_path: "/cancel" } as never}
          />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Question eagerness: collaborative (set by repository).")).toBeInTheDocument()
    expect(screen.getByText("Creates a repair Job and resumes this Job after the repair lands.")).toBeInTheDocument()
    expect(screen.getByText("Cancels the active attempt and closes this Job as cancelled.")).toBeInTheDocument()
    const recovery = screen.getByText("Other recovery options").closest("details")
    expect(recovery).not.toHaveAttribute("open")
    expect(recovery).toContainElement(screen.getByRole("button", { name: "Retry as is" }))

    fireEvent.click(screen.getByRole("button", { name: "File a fix Job" }))
    fireEvent.click(screen.getByRole("button", { name: "Give up" }))
    expect(mutate).toHaveBeenNthCalledWith(1, { method: "post", path: "/api/v1/app/jobs/3/file_question_fix" })
    expect(mutate).toHaveBeenNthCalledWith(2, expect.objectContaining({ method: "post", path: "/cancel" }))

    fireEvent.click(screen.getByText("Other recovery options"))
    expect(recovery).toHaveAttribute("open")
    expect(screen.getByText(/withdraws the unanswered question/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Retry as is" }))
    expect(mutate).toHaveBeenNthCalledWith(3, {
      method: "post",
      path: "/api/v1/app/jobs/3/retry_implementation",
      confirm: "Cancel this attempt, withdraw the question, and start a new implementation attempt?"
    })
  })
})
