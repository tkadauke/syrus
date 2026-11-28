import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import i18n from "../i18n"
import { QuestionInboxDrawer } from "./QuestionInboxDrawer"

describe("QuestionInboxDrawer", () => {
  afterEach(() => vi.restoreAllMocks())

  it("pluralizes the arrival announcement in every locale", async () => {
    try {
      expect(i18n.t("nav:question_inbox.arrived", { count: 1 })).toBe("1 new question arrived.")
      expect(i18n.t("nav:question_inbox.arrived", { count: 3 })).toBe("3 new questions arrived.")
      await i18n.changeLanguage("de")
      expect(i18n.t("nav:question_inbox.arrived", { count: 3 })).toBe("3 neue Fragen sind eingetroffen.")
      await i18n.changeLanguage("la")
      expect(i18n.t("nav:question_inbox.arrived", { count: 3 })).toBe("3 novae quaestiones advenerunt.")
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("supports callers whose existing API fixture omits question data", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <QuestionInboxDrawer />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const trigger = await screen.findByRole("button", { name: "Open questions: 0" })
    fireEvent.click(trigger)
    expect(await screen.findByText("No questions are waiting for an answer.")).toBeInTheDocument()
  })

  it("treats questions already waiting at first load as the baseline, and announces only later arrivals", async () => {
    const question = (id: number) => ({
      id,
      job_id: id,
      job_slug: `JOB-${id}`,
      job_title: `Question ${id}`,
      repository_slug: "acme/widgets",
      asked_at: "2026-01-01T00:00:00Z",
      times_out_at: null,
      questions: [{ question: "Which path?", options: ["Fast", "Careful"], multiple: false }],
      app_answer_path: `/api/v1/app/agent_questions/${id}/answer`,
      job_path: `/jobs/${id}`
    })
    let waiting = [question(1), question(2)]
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ questions: waiting }), { status: 200, headers: { "Content-Type": "application/json" } }))
    )
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <QuestionInboxDrawer />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "Open questions: 2" })).toBeInTheDocument()
    expect(screen.queryByRole("status")).not.toBeInTheDocument()

    waiting = [question(1), question(2), question(3)]
    await client.refetchQueries({ queryKey: ["agent-questions", "open"] })

    expect(await screen.findByRole("button", { name: "Open questions: 3" })).toBeInTheDocument()
    expect(screen.getByRole("status")).toHaveTextContent("1 new question arrived.")
  })

  it("shows the open count and answers with the shared question component", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/agent_questions/7/answer" && init?.method === "POST") {
        return Promise.resolve(new Response(JSON.stringify({ message: "Answer submitted." }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      return Promise.resolve(
        new Response(
          JSON.stringify({
            questions: [
              {
                id: 7,
                job_id: 3,
                job_slug: "JOB-3",
                job_title: "Clarify behavior",
                repository_slug: "acme/widgets",
                asked_at: "2026-01-01T00:00:00Z",
                times_out_at: null,
                questions: [{ question: "Which path?", options: ["Fast", "Careful"], multiple: false }],
                app_answer_path: "/api/v1/app/agent_questions/7/answer",
                job_path: "/jobs/3"
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <QuestionInboxDrawer />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const trigger = await screen.findByRole("button", { name: "Open questions: 1" })
    fireEvent.click(trigger)
    expect(screen.getByRole("link", { name: "JOB-3: Clarify behavior" })).toHaveAttribute("href", "/jobs/3")
    fireEvent.click(screen.getByRole("button", { name: "Careful" }))
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/agent_questions/7/answer", expect.objectContaining({ method: "POST" })))
  })
})
