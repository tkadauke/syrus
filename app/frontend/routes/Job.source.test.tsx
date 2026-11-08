import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { stubVirtualizerMeasurementsForTest } from "../test/virtualizerMeasurements"
import { App } from "./App"
import { jobDetailPayload, jobSourceDiffPayload, jobSourcePayload, jobTimelinePayload } from "../test/app/jobPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App Job source and diff", () => {
  installAppTestLifecycle()

  it("renders the Job source browser from the app source API", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.includes("tree_path=app%2Fmodels")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              jobSourcePayload({
                treePath: "app/models",
                treeItems: [{ path: "app/models/user.rb", name: "user.rb", size: 512, language: "ruby", type: "file" }]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path.includes("tree_path=app")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              jobSourcePayload({ treePath: "app", treeItems: [{ path: "app/models", name: "models", size: 0, language: "plaintext", type: "directory" }] })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path.startsWith("/api/v1/app/jobs/42/source?")) {
        return Promise.resolve(
          new Response(JSON.stringify(jobSourcePayload({ withFile: true })), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path === "/api/v1/app/jobs/42/source") {
        return Promise.resolve(new Response(JSON.stringify(jobSourcePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=source"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const appDirectory = await screen.findByRole("button", { name: "app" })
    expect(appDirectory).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("user.rb")).not.toBeInTheDocument()

    fireEvent.click(appDirectory)
    expect(appDirectory).toHaveAttribute("aria-expanded", "true")
    fireEvent.click(await screen.findByRole("button", { name: "models" }))
    fireEvent.click(await screen.findByTitle("app/models/user.rb (512 B)"))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/source?ref=deadbeef12345678&path=app%2Fmodels%2Fuser.rb",
        expect.objectContaining({ credentials: "same-origin" })
      )
    })
    const keyword = await screen.findByText("class")
    expect(keyword.closest("code")).toHaveTextContent("class User")
  })

  it("loads source folders progressively as they are expanded", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.includes("tree_path=src")) {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              jobSourcePayload({
                treePath: "src",
                treeItems: [{ path: "src/after-the-old-limit.rb", name: "after-the-old-limit.rb", size: 12, language: "ruby", type: "file" }]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }
      if (path === "/api/v1/app/jobs/42/source") {
        return Promise.resolve(
          new Response(JSON.stringify(jobSourcePayload({ treeItems: [{ path: "src", name: "src", size: 0, language: "plaintext", type: "directory" }] })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=source"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "src" })).toHaveAttribute("aria-expanded", "false")
    expect(screen.queryByText("after-the-old-limit.rb")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "src" }))

    expect(await screen.findByText("after-the-old-limit.rb")).toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith(
      "/api/v1/app/jobs/42/source?ref=deadbeef12345678&tree_path=src",
      expect.objectContaining({ credentials: "same-origin" })
    )
  })

  it("switches the Job source browser into diff mode", async () => {
    // Renders the source-browser diff through ReviewableDiff's file-level
    // virtualizer -- see virtualizerMeasurements.ts.
    stubVirtualizerMeasurementsForTest()
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/42/source_diff") {
        return Promise.resolve(new Response(JSON.stringify(jobSourceDiffPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path.startsWith("/api/v1/app/jobs/42/diff_review_comments") && init?.method === "POST") {
        return Promise.resolve(
          new Response(JSON.stringify({ job_id: 42, comments: [], by_path: {} }), { status: 201, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path.startsWith("/api/v1/app/jobs/42/diff_review_comments")) {
        return Promise.resolve(
          new Response(JSON.stringify({ job_id: 42, comments: [], by_path: {} }), { status: 200, headers: { "Content-Type": "application/json" } })
        )
      }
      if (path.startsWith("/api/v1/app/jobs/42/source_diff?")) {
        return Promise.resolve(
          new Response(JSON.stringify(jobSourceDiffPayload({ baseRef: "deadbeef12345678", headRef: "aabbccdd1234567" })), {
            status: 200,
            headers: { "Content-Type": "application/json" }
          })
        )
      }
      if (path === "/api/v1/app/jobs/42/source") {
        return Promise.resolve(new Response(JSON.stringify(jobSourcePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/42/timeline") {
        return Promise.resolve(new Response(JSON.stringify(jobTimelinePayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }

      return Promise.resolve(new Response(JSON.stringify(jobDetailPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/jobs/42?tab=source"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByRole("button", { name: "app" })).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Diff" }))

    expect(await screen.findByText("Select a file to view its diff.")).toBeInTheDocument()
    expect(screen.getByText("app/models/user.rb")).toBeInTheDocument()
    expect(screen.getByText("pycon/tests/unit/homes/helpers/yaml/__init__.py")).toBeInTheDocument()
    expect(screen.queryByText("README.md")).not.toBeInTheDocument()
    expect(screen.getByText("M")).toBeInTheDocument()
    expect(screen.getByText("A")).toBeInTheDocument()

    fireEvent.click(screen.getByText("app/models/user.rb"))
    expect(await screen.findByTestId("agent-diff-viewer")).toBeInTheDocument()
    expect(screen.getByText("old")).toBeInTheDocument()
    expect(screen.getByText("new")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Comment on app/models/user.rb:new:1" }))
    fireEvent.change(screen.getByLabelText("Comment"), { target: { value: "Please cover the new path." } })
    fireEvent.click(screen.getByRole("button", { name: "Create comment" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/diff_review_comments",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining('"surface":"job_source_diff"')
        })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/diff_review_comments",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining('"source_surface":"source_browser"')
        })
      )
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/jobs/42/diff_review_comments",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining('"diff_review_version_id":100')
        })
      )
    })

    fireEvent.click(screen.getByText("pycon/tests/unit/homes/helpers/yaml/__init__.py"))
    expect(screen.getByText("Diff not available (empty, binary, or very large file).")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Continuous" }))
    expect(screen.getByTitle("app/models/user.rb")).toHaveClass("sticky")
    expect(screen.getByText("old")).toBeInTheDocument()
    expect(screen.getByText("new")).toBeInTheDocument()
    // Continuous mode virtualizes files, so the offscreen unavailable-file
    // placeholder is intentionally unmounted until that file enters view.
    expect(screen.queryByText("Diff not available (empty, binary, or very large file).")).not.toBeInTheDocument()

    fireEvent.change(screen.getByLabelText("From"), { target: { value: "deadbeef12345678" } })
    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/jobs/42/source_diff?base=deadbeef12345678", expect.objectContaining({ credentials: "same-origin" }))
    })
  })
})
