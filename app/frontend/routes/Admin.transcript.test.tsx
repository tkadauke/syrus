import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import { transcriptPayload } from "../test/app/chatPayloads"
import { setScrollMetrics } from "../test/app/viewport"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App admin transcript", () => {
  installAppTestLifecycle()

  it("renders the admin transcript route from the app admin transcript API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            run_id: 4,
            job_id: 1,
            step_kind: "implement",
            workflow_trigger_kind: "initial",
            session_id: "abc-123",
            summary: {
              session_id: "abc-123",
              model: "claude-sonnet-4-6",
              cwd: "/workspace",
              total_turns: 1,
              total_tool_calls: 1,
              total_cost_usd: 0.01,
              exit_reason: "success",
              tool_call_counts: { Bash: 1 },
              mcp_tool_called: false,
              available_tools_at_init: ["Bash"]
            },
            pagination: {
              page: 2,
              per: 1,
              total_events: 3,
              total_pages: 3
            },
            events: [
              {
                kind: "tool_use",
                timestamp: "2026-05-30T12:00:00Z",
                data: { name: "Bash", input: { command: "ls" }, id: "u1" }
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/admin/runs/4/transcript?page=2&per=1"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByRole("main", { name: "Admin transcript" })).toBeInTheDocument()
    expect(await screen.findByText("Run #4 · transcript")).toBeInTheDocument()
    expect(screen.getByText(/claude-sonnet-4-6/)).toBeInTheDocument()
    expect(screen.getAllByText("Bash").length).toBeGreaterThan(0)
    expect(screen.getByRole("link", { name: "back to JOB-1" })).toHaveAttribute("href", "/app-shell/jobs/1")
    expect(screen.getByRole("link", { name: "Next" })).toHaveAttribute("href", "/app-shell/admin/runs/4/transcript?page=3&per=1")
    expect(screen.getByRole("link", { name: "Download JSONL" })).toHaveAttribute("href", "/admin/runs/4/transcript/download")
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/admin/runs/4/transcript?page=2&per=1",
      expect.objectContaining({
        credentials: "same-origin",
        headers: { Accept: "application/json" }
      })
    )
  })

  it("keeps the transcript scrolled to the bottom when new events arrive at the bottom", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(transcriptPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/admin/runs/4/transcript"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stream = await screen.findByTestId("transcript-event-stream")
    setScrollMetrics(stream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 600 })
    fireEvent.scroll(stream)
    setScrollMetrics(stream, { scrollHeight: 1200, clientHeight: 400, scrollTop: 600 })

    act(() => {
      queryClient.setQueryData(
        ["admin", "transcript", "4", { page: 1, per: 100 }],
        transcriptPayload({
          totalEvents: 2,
          events: [
            ...transcriptPayload().events,
            {
              kind: "assistant_text",
              timestamp: "2026-05-30T12:01:00Z",
              data: { text: "Fresh transcript event." }
            }
          ]
        })
      )
    })

    expect(await screen.findByText("Fresh transcript event.")).toBeInTheDocument()
    await waitFor(() => expect(stream.scrollTop).toBe(1200))
    expect(screen.queryByRole("button", { name: "New Messages" })).not.toBeInTheDocument()
  })

  it("shows a new messages button when transcript events arrive away from the bottom", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(transcriptPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })

    render(
      <QueryClientProvider client={queryClient}>
        <MemoryRouter initialEntries={["/app-shell/admin/runs/4/transcript"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const stream = await screen.findByTestId("transcript-event-stream")
    setScrollMetrics(stream, { scrollHeight: 1000, clientHeight: 400, scrollTop: 200 })
    fireEvent.scroll(stream)
    setScrollMetrics(stream, { scrollHeight: 1300, clientHeight: 400, scrollTop: 200 })

    act(() => {
      queryClient.setQueryData(
        ["admin", "transcript", "4", { page: 1, per: 100 }],
        transcriptPayload({
          totalEvents: 3,
          events: [
            ...transcriptPayload().events,
            {
              kind: "assistant_text",
              timestamp: "2026-05-30T12:01:00Z",
              data: { text: "First fresh transcript event." }
            },
            {
              kind: "assistant_text",
              timestamp: "2026-05-30T12:02:00Z",
              data: { text: "Second fresh transcript event." }
            }
          ]
        })
      )
    })

    const button = await screen.findByRole("button", { name: "New Messages" })
    expect(stream.scrollTop).toBe(200)

    fireEvent.click(button)
    await waitFor(() => expect(stream.scrollTop).toBe(1300))
    expect(screen.queryByRole("button", { name: "New Messages" })).not.toBeInTheDocument()
  })
})
