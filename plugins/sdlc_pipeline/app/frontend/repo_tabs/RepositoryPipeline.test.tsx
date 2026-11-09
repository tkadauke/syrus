import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { RepositoryPipelineRoute } from "./RepositoryPipeline"

describe("RepositoryPipelineRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it.each([1280, 390])("keeps the %ipx embedded view focused on filters, canvas, and history", async (width) => {
    Object.defineProperty(window, "innerWidth", { configurable: true, value: width })
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      jsonResponse({
        repository: { id: 1, slug: "acme/widgets" },
        generated_at: "2026-10-31T12:00:00Z",
        evidence: { status: "partial", incomplete_count: 2 },
        tabs: [{ key: "sdlc_pipeline.repository", label: "Pipeline", path: "/repositories/1/plugin/sdlc-pipeline" }],
        groups: [],
        stages: [
          {
            key: "review",
            label: "Review",
            kind: "lifecycle",
            total: 0,
            attention_count: 0,
            aging_count: 0,
            oldest_age_seconds: null,
            highlighted_items: []
          }
        ],
        filter: { and: [{ field: "associated_chat_id", op: "is", value: 8 }] },
        filter_schema: [{ field: "associated_chat_id", label: "Chat", bucket: "number", operators: ["is"] }],
        active_smart_folder_id: 7,
        smart_folders: [{ id: 7, name: "Saved cohort", active: true }],
        history: {
          from: "2026-10-30T12:00:00Z",
          to: "2026-10-31T12:00:00Z",
          checkpoint: { at: "2026-10-30T12:00:00Z", placements: [] },
          deltas: [],
          ticks: ["2026-10-31T10:00:00Z"],
          traces: [],
          accuracy: { status: "partial", truncated: true, message: "More history exists." }
        }
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/repositories/1/plugin/sdlc-pipeline?q=chat-filter&syrus_presentation=embedded"]}>
          <RepositoryPipelineRoute repositoryId="1" prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByRole("region", { name: "Pipeline stages" })
    const embedded = screen.getByTestId("embedded-pipeline-view")
    expect(within(embedded).getByRole("button", { name: "Chat is 8" })).toBeVisible()
    expect(within(embedded).getByRole("region", { name: "Pipeline stages" })).toBeVisible()
    expect(within(embedded).getByTestId("compact-pipeline-time-rail")).toBeVisible()
    expect(within(embedded).queryByText("Saved cohort")).not.toBeInTheDocument()
    expect(within(embedded).queryByLabelText("Pipeline summary")).not.toBeInTheDocument()
    expect(within(embedded).queryByText(/Delivery evidence is partial/)).not.toBeInTheDocument()
    expect(within(embedded).queryByText("More history exists.")).not.toBeInTheDocument()
    expect(within(embedded).queryByText("SDLC Pipeline")).not.toBeInTheDocument()
  })

  it("renders bounded stage summaries, evidence, and attention highlights", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      jsonResponse({
        repository: { id: 1, slug: "acme/widgets" },
        generated_at: "2026-10-31T12:00:00Z",
        evidence: { status: "complete", incomplete_count: 0 },
        tabs: [{ key: "sdlc_pipeline.repository", label: "Pipeline", path: "/repositories/1/plugin/sdlc-pipeline" }],
        groups: [
          {
            key: "epic:2",
            label: "Release reliability",
            epic: { id: 2, slug: "EPIC-2", title: "Release reliability" },
            total: 10,
            stage_totals: { review: 10 }
          },
          { key: "ungrouped", label: "Ungrouped", total: 2, stage_totals: { review: 2 } }
        ],
        stages: [
          {
            key: "review",
            label: "Review",
            kind: "lifecycle",
            total: 12,
            attention_count: 2,
            aging_count: 4,
            oldest_age_seconds: 100,
            highlighted_items: [
              {
                id: 9,
                slug: "JOB-9",
                title: "Explain placement",
                state: "implemented",
                needs_attention: true,
                age_seconds: 50,
                paths: { job: "/jobs/JOB-9", workflow: "/jobs/JOB-9?tab=workflows#workflow-3" },
                evidence: { type: "job_state", state: "implemented" }
              }
            ]
          }
        ]
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <RepositoryPipelineRoute repositoryId="1" prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("acme/widgets")).toBeInTheDocument()
    expect(screen.getByText("2 attention")).toBeInTheDocument()
    expect(screen.getByText("4 aging")).toBeInTheDocument()
    expect(screen.getByText("Explain placement")).toBeInTheDocument()
    expect(screen.getByText("JOB-9")).toBeInTheDocument()
    expect(screen.getByText("Job state")).toBeInTheDocument()
    expect(screen.getByText("Release reliability")).toBeInTheDocument()
    expect(screen.getByText("12 items represented")).toBeInTheDocument()
    expect(screen.getByTestId("pipeline-time-rail")).toBeVisible()
    expect(screen.getByTestId("pipeline-with-time-rail")).toContainElement(screen.getByRole("region", { name: "Pipeline stages" }))
    expect(screen.getByText(/No deployment stages are configured/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Workflow" })).toHaveAttribute("href", "/jobs/JOB-9?tab=workflows#workflow-3")
  })

  it("opens an accessible drill-down and restores focus when Escape closes it", async () => {
    const overview = {
      repository: { id: 1, slug: "acme/widgets" },
      generated_at: "2026-10-31T12:00:00Z",
      evidence: { status: "partial", incomplete_count: 1 },
      tabs: [],
      groups: [],
      stages: [
        {
          key: "deployment:production",
          label: "Production",
          kind: "deployment",
          release_tail: true,
          total: 1,
          attention_count: 0,
          aging_count: 0,
          oldest_age_seconds: 60,
          highlighted_items: [
            {
              id: 9,
              slug: "JOB-9",
              title: "Ship it",
              state: "closed",
              needs_attention: false,
              age_seconds: 60,
              paths: { job: "/jobs/JOB-9", delivery: "/jobs/JOB-9", release: "/jobs/JOB-9" },
              evidence: { type: "deployment_stage", stage_name: "production" }
            }
          ]
        }
      ]
    }
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes("?stage="))
        return jsonResponse({
          ...overview,
          drill_down: { stage: "deployment:production", page: 1, limit: 25, total: 1, next_page: null, items: overview.stages[0].highlighted_items }
        })
      return jsonResponse(overview)
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <RepositoryPipelineRoute repositoryId="1" prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText(/Delivery evidence is partial/)).toBeInTheDocument()
    const opener = screen.getByRole("region", { name: "Production, 1 items" }).querySelector("button") as HTMLButtonElement
    opener.focus()
    fireEvent.click(opener)
    const dialog = await screen.findByRole("dialog", { name: "Production stage details" })
    const closeButton = screen.getByRole("button", { name: "Close details" })
    await waitFor(() => expect(closeButton).toHaveFocus())
    expect(closeButton.querySelector("svg")).toBeInTheDocument()
    expect(within(dialog).getByRole("link", { name: "Release" })).toHaveAttribute("href", "/jobs/JOB-9")
    fireEvent.keyDown(document, { key: "Escape" })
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    expect(opener).toHaveFocus()
  })

  it("round-trips the canonical filter query through overview requests", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(() =>
      Promise.resolve(
        jsonResponse({
          repository: { id: 1, slug: "acme/widgets" },
          generated_at: "2026-10-31T12:00:00Z",
          evidence: { status: "complete", incomplete_count: 0 },
          tabs: [],
          groups: [],
          stages: [],
          filter: { and: [{ field: "owner_user_id", op: "is", value: "me" }] },
          filter_schema: [{ field: "owner_user_id", label: "Owner", bucket: "enum", operators: ["is"], values: [{ value: "me", label: "Me" }] }],
          active_smart_folder_id: 7,
          smart_folders: [
            {
              id: 7,
              name: "Mine",
              position: 1,
              kind: "builtin",
              subject_type: "sdlc_pipeline",
              visibility: "always",
              count: 0,
              active: true,
              filter: { and: [{ field: "owner_user_id", op: "is", value: "me" }] },
              path: "/repositories/1/plugin/sdlc-pipeline?smart_folder_id=7"
            }
          ]
        })
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/repositories/1/plugin/sdlc-pipeline?q=encoded-tree"]}>
          <RepositoryPipelineRoute repositoryId="1" prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("acme/widgets")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(expect.stringContaining("/sdlc_pipeline?q=encoded-tree"), expect.anything())
    expect(screen.getByRole("link", { name: /Mine/ })).toHaveAttribute("href", "/repositories/1/plugin/sdlc-pipeline?smart_folder_id=7")
  })

  it("reconstructs a historical tick without requesting the at presentation state", async () => {
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockImplementation(() =>
      Promise.resolve(
        jsonResponse({
          repository: { id: 1, slug: "acme/widgets" },
          generated_at: "2026-10-31T12:00:00Z",
          evidence: { status: "complete", incomplete_count: 0 },
          tabs: [],
          groups: [],
          stages: [
            { key: "review", label: "Review", kind: "lifecycle", total: 0, attention_count: 0, aging_count: 0, oldest_age_seconds: null, highlighted_items: [] }
          ],
          history: {
            from: "2026-10-30T12:00:00Z",
            to: "2026-10-31T12:00:00Z",
            checkpoint: { at: "2026-10-30T12:00:00Z", placements: [] },
            deltas: [
              {
                at: "2026-10-31T10:00:00Z",
                job_id: 9,
                from_stage: "implementing",
                to_stage: "review",
                item: {
                  job_id: 9,
                  stage: "review",
                  item: {
                    id: 9,
                    slug: "JOB-9",
                    title: "Historical card",
                    state: "closed",
                    paths: { job: "/jobs/JOB-9" },
                    metadata_as_of: "2026-10-31T12:00:00Z"
                  }
                }
              },
              {
                at: "2026-10-31T11:00:00Z",
                job_id: 9,
                from_stage: "review",
                to_stage: "deployment:production"
              },
              {
                at: "2026-10-31T11:30:00Z",
                job_id: 9,
                from_stage: "deployment:production",
                to_stage: "blocked"
              }
            ],
            ticks: ["2026-10-31T10:00:00Z", "2026-10-31T11:00:00Z", "2026-10-31T11:30:00Z"],
            traces: [{ job_id: 9, segments: [{ stage: "review", entered_at: "2026-10-31T10:00:00Z", left_at: "2026-10-31T12:00:00Z", dwell_seconds: 7200 }] }],
            accuracy: { status: "reconstructed", truncated: false, message: "Stage placement is reconstructed. Card metadata is current." }
          }
        })
      )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/repositories/1/plugin/sdlc-pipeline?q=associated-chat&at=2026-10-31T10%3A00%3A00Z"]}>
          <RepositoryPipelineRoute repositoryId="1" prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("Historical card")).toBeInTheDocument()
    expect(screen.getByRole("region", { name: "Pipeline stages" })).toBeInTheDocument()
    expect(screen.getByTestId("pipeline-time-rail")).toBeInTheDocument()
    expect(screen.getByLabelText("Historical time")).toHaveStyle({ direction: "rtl", writingMode: "vertical-lr" })
    expect(screen.queryByRole("button", { name: /View pipeline at/ })).not.toBeInTheDocument()
    expect(screen.getByText("Reconstructed placement; current metadata")).toBeInTheDocument()
    expect(screen.getByText("Stage placement is reconstructed. Card metadata is current.")).toBeInTheDocument()
    expect(screen.getByText(/This view is read-only/)).toBeInTheDocument()
    expect(screen.getByText(/1 placement changed/)).toBeInTheDocument()
    const movementMark = screen.getByRole("button", { name: /stage movement/ })
    expect(movementMark).toBeInTheDocument()
    expect(movementMark).toHaveClass("ring-2")
    expect(screen.getByRole("button", { name: /deployment/ })).toHaveTextContent("◆")
    expect(screen.getByRole("button", { name: /failure or blocked work/ })).toHaveTextContent("!")
    expect(screen.getByTestId("pipeline-time-rail")).toBeVisible()
    expect(screen.getByText("JOB-9: implementing → review")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Previous event" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Next event" })).toBeInTheDocument()
    expect(screen.getByLabelText("History window")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "View trace" }))
    expect(screen.getByText("Trace for JOB-9")).toBeInTheDocument()
    expect(screen.getByText(/entered/)).toBeInTheDocument()
    fireEvent.click(screen.getByText("Options"))
    fireEvent.change(screen.getByLabelText("History window"), { target: { value: "30" } })
    await waitFor(() =>
      expect(
        fetchSpy.mock.calls.some(
          ([url]) => String(url).includes("q=associated-chat") && String(url).includes("range_start=") && String(url).includes("range_end=")
        )
      ).toBe(true)
    )
    expect(String(fetchSpy.mock.calls[0][0])).not.toContain("at=")
    fireEvent.click(screen.getByRole("button", { name: /deployment/ }))
    await waitFor(() => expect(screen.queryByText("Historical card")).not.toBeInTheDocument())
    expect(screen.getByTestId("selected-history-time")).toHaveAttribute("datetime", "2026-10-31T11:00:00.000Z")
    fireEvent.click(movementMark)
    await waitFor(() => expect(screen.getByText("Historical card")).toBeInTheDocument())
    fireEvent.click(await screen.findByRole("button", { name: "Return to now" }))
    await waitFor(() => expect(screen.queryByText(/This view is read-only/)).not.toBeInTheDocument())
    expect(fetchSpy.mock.calls.length).toBeGreaterThanOrEqual(4)
  })
  describe("history states", () => {
    const base = {
      repository: { id: 1, slug: "acme/widgets" },
      generated_at: "2026-10-31T12:00:00Z",
      evidence: { status: "complete", incomplete_count: 0 },
      tabs: [],
      groups: [],
      stages: [
        { key: "review", label: "Review", kind: "lifecycle", total: 0, attention_count: 0, aging_count: 0, oldest_age_seconds: null, highlighted_items: [] }
      ]
    }
    const historyBody = (ticks: string[], accuracyStatus: "reconstructed" | "incomplete" = "reconstructed") => ({
      ...base,
      history: {
        from: "2026-10-30T12:00:00Z",
        to: "2026-10-31T12:00:00Z",
        checkpoint: { at: "2026-10-30T12:00:00Z", placements: [] },
        deltas: [],
        ticks,
        traces: [],
        accuracy: { status: accuracyStatus, truncated: false, message: "" }
      }
    })
    function mockFetch(history: () => Promise<Response>) {
      vi.spyOn(globalThis, "fetch").mockImplementation((input) => (String(input).includes("history=1") ? history() : Promise.resolve(jsonResponse(base))))
    }
    function renderRoute(search = "") {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={[`/repositories/1/plugin/sdlc-pipeline${search}`]}>
            <RepositoryPipelineRoute repositoryId="1" prefix="" />
          </MemoryRouter>
        </QueryClientProvider>
      )
    }

    it("renders exactly one navigator and window selector full-page, with markers when ticks exist", async () => {
      mockFetch(() => Promise.resolve(jsonResponse(historyBody(["2026-10-31T10:00:00Z", "2026-10-31T11:00:00Z"]))))
      renderRoute()
      await screen.findByRole("region", { name: "Pipeline stages" })
      await waitFor(() => expect(screen.getByTestId("history-event-track").querySelectorAll("button")).toHaveLength(2))
      const toolbar = within(screen.getByTestId("pipeline-toolbar"))
      expect(toolbar.getByRole("heading", { name: "SDLC Pipeline" })).toBeInTheDocument()
      expect(toolbar.getByLabelText("Pipeline summary")).toBeInTheDocument()
      expect(toolbar.getByRole("textbox", { name: "Filter pipeline" })).toBeInTheDocument()
      expect(screen.getAllByLabelText("History window")).toHaveLength(1)
      expect(screen.getAllByTestId("pipeline-time-rail")).toHaveLength(1)
      expect(screen.queryByTestId("compact-pipeline-time-rail")).not.toBeInTheDocument()
      expect(screen.queryByTestId("history-status")).not.toBeInTheDocument()
      await waitFor(() => {
        expect(screen.getByRole("button", { name: "Play" })).toBeEnabled()
        expect(screen.getByRole("button", { name: "Previous event" })).toBeEnabled()
      })
      fireEvent.click(screen.getByRole("button", { name: "Previous event" }))
      await waitFor(() => expect(screen.getByTestId("selected-history-time")).toHaveAttribute("datetime", "2026-10-31T11:00:00.000Z"))
      fireEvent.click(screen.getByRole("button", { name: "Previous event" }))
      await waitFor(() => expect(screen.getByTestId("selected-history-time")).toHaveAttribute("datetime", "2026-10-31T10:00:00.000Z"))
    })

    it("shows a pending state while history loads and keeps the pipeline usable", async () => {
      mockFetch(() => new Promise<Response>(() => {}))
      renderRoute()
      await screen.findByRole("region", { name: "Pipeline stages" })
      expect(screen.getByTestId("history-status")).toHaveAttribute("data-history-status", "loading")
      expect(screen.getByText("Loading history…")).toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Play" })).toBeDisabled()
    })

    it("shows a failure with retry that recovers", async () => {
      let calls = 0
      mockFetch(() => {
        calls += 1
        return Promise.resolve(calls === 1 ? new Response("boom", { status: 500 }) : jsonResponse(historyBody(["2026-10-31T10:00:00Z"])))
      })
      renderRoute()
      await screen.findByRole("region", { name: "Pipeline stages" })
      const status = await screen.findByText(/History could not be loaded/)
      expect(status).toBeInTheDocument()
      expect(screen.getByTestId("history-status")).toHaveAttribute("data-history-status", "error")
      fireEvent.click(screen.getByRole("button", { name: "Retry history" }))
      await waitFor(() => expect(screen.queryByTestId("history-status")).not.toBeInTheDocument())
    })

    it("explains an empty history window", async () => {
      mockFetch(() => Promise.resolve(jsonResponse(historyBody([]))))
      renderRoute()
      await screen.findByRole("region", { name: "Pipeline stages" })
      await waitFor(() => expect(screen.getByTestId("history-status")).toHaveAttribute("data-history-status", "empty"))
      expect(screen.getByText(/No pipeline changes were recorded/)).toBeInTheDocument()
    })

    it("distinguishes incomplete evidence from a genuinely empty window", async () => {
      const body = historyBody([], "incomplete")
      mockFetch(() => Promise.resolve(jsonResponse(body)))
      renderRoute()
      await screen.findByRole("region", { name: "Pipeline stages" })
      await waitFor(() => expect(screen.getByTestId("history-status")).toHaveAttribute("data-history-status", "incomplete"))
      expect(screen.getByText(/cannot safely reconstruct/)).toBeInTheDocument()
      expect(screen.queryByText(/No pipeline changes were recorded/)).not.toBeInTheDocument()
      expect(screen.getByRole("button", { name: "Play" })).toBeDisabled()
    })

    it("keeps a single compact navigator when embedded", async () => {
      mockFetch(() => Promise.resolve(jsonResponse(historyBody(["2026-10-31T10:00:00Z"]))))
      renderRoute("?syrus_presentation=embedded")
      await screen.findByRole("region", { name: "Pipeline stages" })
      expect(screen.getAllByTestId("compact-pipeline-time-rail")).toHaveLength(1)
      expect(screen.queryByTestId("pipeline-time-rail")).not.toBeInTheDocument()
      expect(screen.getAllByLabelText(/History window/)).toHaveLength(1)
    })

    it("fills the modal height and renders a scrollable, labelled, time-scaled rail when embedded", async () => {
      const body = historyBody(["2026-10-31T10:00:00Z", "2026-10-31T10:00:30Z", "2026-10-31T11:00:00Z"])
      body.history.from = "2026-10-24T12:00:00Z"
      body.history.deltas = [
        { at: "2026-10-31T10:00:00Z", job_id: 1, from_stage: "review", to_stage: "failed", item: null },
        { at: "2026-10-31T11:00:00Z", job_id: 2, from_stage: "review", to_stage: "deployment:prod", item: null }
      ] as never
      mockFetch(() => Promise.resolve(jsonResponse(body)))
      renderRoute("?syrus_presentation=embedded&at=2026-10-31T10:00:00Z")
      await screen.findByRole("region", { name: "Pipeline stages" })

      expect(screen.getByTestId("embedded-pipeline-view").className).toContain("h-[100dvh]")
      expect(screen.getByTestId("pipeline-with-time-rail").className).toContain("flex-1")
      expect(document.querySelector('[data-stage="review"]')?.className).toContain("h-full")
      expect(document.querySelector('[data-stage="review"]')?.className).not.toContain("h-[31rem]")

      const scroll = screen.getByTestId("history-rail-scroll")
      expect(scroll.className).toContain("overflow-y-auto")
      const content = screen.getByTestId("history-rail-content")
      expect(parseInt(content.style.height, 10)).toBeGreaterThan(1500)
      expect(screen.getAllByTestId("history-rail-label").length).toBeGreaterThan(6)

      const ticks = Array.from(scroll.querySelectorAll<HTMLElement>("button[data-event-kind]"))
      expect(ticks.map((tick) => tick.dataset.eventKind)).toEqual(["attention", "movement", "deployment"])
      const tops = ticks.map((tick) => parseFloat(tick.style.top))
      expect(tops[0] - tops[1]).toBeGreaterThanOrEqual(13) // 30s apart, still separated
      expect(ticks[0]).toHaveAttribute("aria-pressed", "true")
      expect(screen.getByTestId("history-rail-cursor")).toBeInTheDocument()
      expect(within(screen.getByTestId("compact-pipeline-time-rail")).getByTestId("selected-history-time")).toHaveTextContent(/Oct 31/)
      expect(screen.getAllByTestId("history-rail-label")[0].className).not.toContain("truncate")
      expect(screen.getByTestId("history-rail-cursor").className).not.toContain("right-")
      expect(screen.getByRole("slider", { name: /Historical time/ })).toBeInTheDocument()
    })
  })
})
