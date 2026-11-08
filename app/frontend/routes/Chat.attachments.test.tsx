import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import { MemoryRouter } from "react-router-dom"
import { App } from "./App"
import * as videoWalkthroughs from "../api/videoWalkthroughs"
import { chatPayload } from "../test/app/chatPayloads"
import { installAppTestLifecycle } from "../test/app/lifecycle"

vi.mock("@rails/actioncable", async () => (await import("../test/app/appMocks")).actionCableModule())
vi.mock("@excalidraw/excalidraw", async () => (await import("../test/app/appMocks")).excalidrawModule())
vi.mock("html2canvas-pro", async () => (await import("../test/app/appMocks")).html2canvasModule())

describe("App chat attachments and walkthroughs", () => {
  installAppTestLifecycle()

  it("renders a chat attachment add button in the composer", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload(),
            paths: {
              ...chatPayload().paths,
              app_video_walkthroughs_path: "/api/v1/app/chats/8/video_walkthroughs",
              app_video_walkthrough_retry_path: "/api/v1/app/video_walkthroughs/:id/retry"
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const addAttachment = screen.getByRole("button", { name: "Add attachment" })
    expect(addAttachment).toHaveTextContent("+")
    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
    expect(screen.getByLabelText("Chat attachments")).not.toHaveAttribute("accept")
  })

  it("gates video intake behind the walkthroughs labs flag", async () => {
    // chatPayload() contributes no app_video_walkthroughs_path — which is
    // what a disabled video_walkthroughs plugin looks like to the composer.
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify({ ...chatPayload(), gemini_configured: true }), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")

    // The picker stays unfiltered so exact extensionless filenames such as
    // Dockerfile remain selectable; validation still rejects disabled video.
    expect(screen.getByLabelText("Chat attachments")).not.toHaveAttribute("accept")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    expect(await screen.findByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    expect(screen.queryByText("Record a walkthrough")).not.toBeInTheDocument()

    // A dropped video does NOT become a walkthrough draft.
    const form = screen.getByPlaceholderText("Ask about this repository...").closest("form") as HTMLElement
    const video = new File(["v"], "walkthrough.webm", { type: "video/webm" })
    fireEvent.drop(form, { dataTransfer: { files: [video] } })
    await waitFor(() => {
      expect(screen.queryByTestId("walkthrough-chip")).not.toBeInTheDocument()
    })
  })

  it("blocks sending a ready walkthrough alongside image attachments", async () => {
    // Gemini must be configured or the drop opens the setup sheet instead of
    // creating a walkthrough draft (chatPayload defaults gemini_configured off).
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload(),
            gemini_configured: true,
            paths: {
              ...chatPayload().paths,
              app_video_walkthroughs_path: "/api/v1/app/chats/8/video_walkthroughs",
              app_video_walkthrough_retry_path: "/api/v1/app/video_walkthroughs/:id/retry"
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )
    // jsdom implements neither media metadata nor URL.createObjectURL, so the
    // real measureVideoDuration would hang the intake await; resolve it here.
    vi.spyOn(videoWalkthroughs, "measureVideoDuration").mockImplementation(async () => 30)

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const form = screen.getByPlaceholderText("Ask about this repository...").closest("form") as HTMLElement

    // One drop carrying a video AND an image: the video becomes the walkthrough
    // draft, the image becomes a normal chat attachment — the exact combo the
    // review finding said must not be sendable together.
    const video = new File(["v"], "walkthrough.webm", { type: "video/webm" })
    const image = new File(["i"], "screenshot.png", { type: "image/png" })
    fireEvent.drop(form, { dataTransfer: { files: [video, image] } })

    // Walkthrough draft settles to "ready", image attachment chip appears.
    expect(await screen.findByTestId("walkthrough-chip")).toHaveTextContent("Ready")
    await screen.findByText("screenshot.png")

    const messageCallsBefore = fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/message")).length
    fireEvent.submit(form)

    // Explicit block, not a silent split: the copy from the en locale.
    expect(
      await screen.findByText("Send the walkthrough on its own — remove image or file attachments and send them in a separate message.")
    ).toBeInTheDocument()
    // Nothing was sent — no message POST, no upload attempt.
    expect(fetchSpy.mock.calls.filter(([url]) => String(url).endsWith("/message")).length).toBe(messageCallsBefore)
  })

  it("blocks dropping a second walkthrough while the first is uploading", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () =>
        new Response(
          JSON.stringify({
            ...chatPayload(),
            gemini_configured: true,
            paths: {
              ...chatPayload().paths,
              app_video_walkthroughs_path: "/api/v1/app/chats/8/video_walkthroughs",
              app_video_walkthrough_retry_path: "/api/v1/app/video_walkthroughs/:id/retry"
            }
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )
    vi.spyOn(videoWalkthroughs, "measureVideoDuration").mockImplementation(async () => 30)
    // Hold the upload in-flight so the draft stays "uploading" — a settled
    // (ready/failed) draft is replaceable; only an in-flight one is guarded.
    const uploadSpy = vi.spyOn(videoWalkthroughs, "uploadVideoWalkthrough").mockReturnValue(new Promise(() => {}))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const form = screen.getByPlaceholderText("Ask about this repository...").closest("form") as HTMLElement

    const first = new File(["v1"], "first.webm", { type: "video/webm" })
    fireEvent.drop(form, { dataTransfer: { files: [first] } })
    expect(await screen.findByTestId("walkthrough-chip")).toHaveTextContent("Ready")

    // Send commits the walkthrough — the upload starts and hangs, so the draft
    // is now "uploading".
    fireEvent.submit(form)
    await waitFor(() => expect(uploadSpy).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(screen.getByTestId("walkthrough-chip")).toHaveTextContent(/Uploading/))

    // Dropping a second video now must trip the one-at-a-time guard.
    const second = new File(["v2"], "second.webm", { type: "video/webm" })
    fireEvent.drop(form, { dataTransfer: { files: [second] } })

    expect(await screen.findByText("A walkthrough is already being processed — wait for it to finish, then add another.")).toBeInTheDocument()
    // The in-flight draft was not replaced: still showing the first upload,
    // and no second upload was kicked off.
    expect(uploadSpy).toHaveBeenCalledTimes(1)
    expect(screen.getByTestId("walkthrough-chip")).toHaveTextContent("first.webm")
  })

  it("opens and dismisses the chat attachment popover from the compose button", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    expect(screen.getByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Upload file" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Scratch pad" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Repo" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Epic" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Job" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Doc" })).not.toBeInTheDocument()

    fireEvent.keyDown(screen.getByRole("dialog", { name: "Add attachment" }), { key: "Escape" })
    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
    expect(screen.getByRole("dialog", { name: "Add attachment" })).toBeInTheDocument()
    fireEvent.pointerDown(document.body)
    expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
  })

  it("triggers the chat file input from the attachment popover", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )
    const inputClickSpy = vi.spyOn(HTMLInputElement.prototype, "click").mockImplementation(() => undefined)

    try {
      render(
        <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
          <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
            <App />
          </MemoryRouter>
        </QueryClientProvider>
      )

      await screen.findByPlaceholderText("Ask about this repository...")
      fireEvent.click(screen.getByRole("button", { name: "Add attachment" }))
      fireEvent.click(screen.getByRole("button", { name: "Upload file" }))

      expect(inputClickSpy).toHaveBeenCalled()
      expect(screen.queryByRole("dialog", { name: "Add attachment" })).not.toBeInTheDocument()
    } finally {
      inputClickSpy.mockRestore()
    }
  })

  it("adds a selected chat attachment chip with a remove button", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const file = new File(["chart"], "flow-chart.png", { type: "image/png" })
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [file] } })

    expect(await screen.findByText("flow-chart.png")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Remove flow-chart.png" })).toBeInTheDocument()
  })

  it("removes a selected chat attachment chip", async () => {
    vi.spyOn(window, "fetch").mockImplementation(
      async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    await screen.findByPlaceholderText("Ask about this repository...")
    const file = new File(["pdf"], "brief.pdf", { type: "application/pdf" })
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [file] } })

    expect(await screen.findByText("brief.pdf")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Remove brief.pdf" }))
    expect(screen.queryByText("brief.pdf")).not.toBeInTheDocument()
  })

  it("sends chat message attachments in the JSON payload", async () => {
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation((input, init) => {
      const path = String(input)
      if (path === "/api/v1/app/chats/8/message" && init?.method === "POST") {
        return Promise.resolve(
          new Response(
            JSON.stringify(
              chatPayload({
                messages: [
                  ...chatPayload().messages,
                  {
                    type: "message",
                    id: 10,
                    role: "user",
                    text: "Review this diagram",
                    bookmarkable: true
                  }
                ]
              })
            ),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        )
      }

      return Promise.resolve(new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [new File(["chart"], "flow-chart.png", { type: "image/png" })] } })
    expect(await screen.findByText("flow-chart.png")).toBeInTheDocument()
    fireEvent.change(input, { target: { value: "Review this diagram" } })
    fireEvent.click(screen.getByRole("button", { name: "Send message" }))

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith(
        "/api/v1/app/chats/8/message",
        expect.objectContaining({
          method: "POST",
          body: expect.stringContaining(
            '"chat_message":{"text":"Review this diagram","attachments":[{"name":"flow-chart.png","mime_type":"image/png","data":"Y2hhcnQ="}]}'
          )
        })
      )
    })
    await waitFor(() => expect(screen.queryByText("flow-chart.png")).not.toBeInTheDocument())
  })

  it("blocks chat attachment submission when a file is larger than 5 MB", async () => {
    const fetchSpy = vi
      .spyOn(window, "fetch")
      .mockImplementation(async () => new Response(JSON.stringify(chatPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter initialEntries={["/app-shell/chats/8"]}>
          <App />
        </MemoryRouter>
      </QueryClientProvider>
    )

    const input = await screen.findByPlaceholderText("Ask about this repository...")
    const oversized = new File([new Uint8Array(5 * 1024 * 1024 + 1)], "too-large.png", { type: "image/png" })
    fireEvent.change(screen.getByLabelText("Chat attachments"), { target: { files: [oversized] } })
    expect(await screen.findByText("Each attachment must be 5 MB or smaller.")).toBeInTheDocument()

    fireEvent.change(input, { target: { value: "Try sending this" } })
    expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled()
    expect(fetchSpy).not.toHaveBeenCalledWith("/api/v1/app/chats/8/message", expect.objectContaining({ method: "POST" }))
  })
})
