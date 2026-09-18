import { useRef } from "react"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import html2canvasModule from "html2canvas-pro"
import { MemoryRouter } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import * as chatsApi from "@app/api/chats"
import type { ToolPresentationEntry, ToolPresentationExample } from "@app/toolPresentationRegistry"
import * as toolCardJobsApi from "../api/toolCardJobs"
import {
  buildToolCardFeedbackMetadata,
  buildToolCardFeedbackPrompt,
  ToolCardDiscussButton,
  type ToolCardFeedbackMetadata
} from "./ToolCardDiscussDialog"

const { mockNavigate } = vi.hoisted(() => ({ mockNavigate: vi.fn() }))

vi.mock("react-router-dom", async (importOriginal) => {
  const actual = await importOriginal<typeof import("react-router-dom")>()
  return { ...actual, useNavigate: () => mockNavigate }
})

vi.mock("@app/api/chats", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@app/api/chats")>()
  return { ...actual, createChat: vi.fn() }
})

vi.mock("../api/toolCardJobs", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../api/toolCardJobs")>()
  return { ...actual, createToolCardJob: vi.fn() }
})

vi.mock("html2canvas-pro", () => ({
  default: vi.fn()
}))

const mockCreateChat = vi.mocked(chatsApi.createChat)
const mockCreateToolCardJob = vi.mocked(toolCardJobsApi.createToolCardJob)
const mockHtml2canvas = vi.mocked(html2canvasModule)

const entry: ToolPresentationEntry = {
  toolName: "list_insights",
  aliases: [],
  ownerType: "plugin",
  ownerName: "agent_insights",
  sourceType: "mcp_tool",
  readOnly: true,
  displayLabel: "List insights",
  progressLabel: "Listing insights...",
  argumentSummary: () => "",
  renderer: null,
  examples: []
}

const example: ToolPresentationExample = {
  id: "two_open",
  label: "Two open insights",
  input: { state: "pending" },
  parsedResult: { insights: [ { id: 1, title: "LandingQueueProcessor re-fetches PR mergeability on every poll tick" } ] }
}

const deepLink = "https://syrus.test/admin/tool_cards?tool=list_insights&example=two_open#tool-list_insights"

function Harness() {
  const previewRef = useRef<HTMLDivElement | null>(null)
  return (
    <>
      <div ref={previewRef}>rendered preview</div>
      <ToolCardDiscussButton deepLink={deepLink} entry={entry} example={example} previewRef={previewRef} viewportPresetId="desktop" />
    </>
  )
}

function renderHarness() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/admin/tool_cards"]}>
        <Harness />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

async function openDialog() {
  fireEvent.click(screen.getByRole("button", { name: "Discuss this card" }))
  await screen.findByRole("dialog")
}

describe("buildToolCardFeedbackMetadata", () => {
  it("carries the full structured payload the acceptance criteria calls out", () => {
    const metadata = buildToolCardFeedbackMetadata(entry, example, "phone", deepLink, [])

    expect(metadata).toEqual<ToolCardFeedbackMetadata>({
      tool_name: "List insights",
      canonical_name: "list_insights",
      owner_type: "plugin",
      owner_name: "agent_insights",
      source_type: "mcp_tool",
      renderer_type: "generic_fallback",
      read_only: true,
      selected_example_id: "two_open",
      selected_viewport_preset: "phone",
      input_payload: { state: "pending" },
      result_body: JSON.stringify(example.parsedResult),
      result_payload: example.parsedResult,
      result_error: false,
      catalog_deep_link: deepLink,
      annotations: []
    })
  })

  it("flags a resultError example and preserves any annotation shapes passed in", () => {
    const errorExample: ToolPresentationExample = { id: "boom", label: "Failure", resultBody: "boom", resultError: true }
    const shapes = [ { id: "s1", kind: "text" as const, x: 1, y: 2, value: "look here", color: "#ef4444" } ]

    const metadata = buildToolCardFeedbackMetadata(entry, errorExample, "wide", deepLink, shapes)

    expect(metadata.result_error).toBe(true)
    expect(metadata.result_body).toBe("boom")
    expect(metadata.annotations).toEqual(shapes)
  })
})

describe("buildToolCardFeedbackPrompt", () => {
  it("uses the operator's prompt as the heading and appends a readable summary plus the raw JSON", () => {
    const metadata = buildToolCardFeedbackMetadata(entry, example, "desktop", deepLink, [])
    const text = buildToolCardFeedbackPrompt("This card renders the wrong icon.", metadata)

    expect(text.startsWith("This card renders the wrong icon.")).toBe(true)
    expect(text).toContain("Tool: List insights (`list_insights`)")
    expect(text).toContain("Owner: plugin · agent_insights")
    expect(text).toContain(`Catalog link: ${deepLink}`)
    expect(text).toContain("```json")
    expect(text).toContain(JSON.stringify(metadata, null, 2))
  })

  it("falls back to a default heading naming the tool when the operator leaves the prompt blank", () => {
    const metadata = buildToolCardFeedbackMetadata(entry, example, "desktop", deepLink, [])
    const text = buildToolCardFeedbackPrompt("   ", metadata)

    expect(text.startsWith('Discuss the "List insights" tool card in the Tool Card Catalog.')).toBe(true)
  })
})

describe("ToolCardDiscussButton", () => {
  beforeEach(() => {
    mockNavigate.mockClear()
    mockCreateChat.mockReset()
    mockCreateToolCardJob.mockReset()
    mockHtml2canvas.mockReset()
  })

  it("captures a screenshot of the scoped preview element and shows it in the dialog", async () => {
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,c2NyZWVuc2hvdA==" } as unknown as HTMLCanvasElement)

    renderHarness()
    await openDialog()

    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toHaveAttribute("src", "data:image/png;base64,c2NyZWVuc2hvdA=="))

    const previewNode = screen.getByText("rendered preview")
    expect(mockHtml2canvas.mock.calls[0][0]).toBe(previewNode)
  })

  it("shows a clear inline error and keeps the raw metadata available when capture fails", async () => {
    mockHtml2canvas.mockRejectedValue(new Error("tainted canvas"))

    renderHarness()
    await openDialog()

    await screen.findByText("Couldn't capture a screenshot of this card. You can still start the chat without one — the metadata below is still included.")
    expect(screen.queryByRole("img", { name: "Screenshot of the List insights card" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByText("Raw payload metadata"))
    expect(screen.getByText(/"canonical_name": "list_insights"/)).toBeInTheDocument()
  })

  it("lets the operator annotate the captured screenshot with the shared annotation tool", async () => {
    setUpAnnotationCanvasMocks()
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,c2NyZWVuc2hvdA==" } as unknown as HTMLCanvasElement)

    renderHarness()
    await openDialog()
    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toBeInTheDocument())

    fireEvent.click(screen.getByRole("button", { name: "Annotate screenshot" }))
    const annotationDialog = await screen.findByRole("dialog", { name: "Annotate list_insights-tool-card.png" })

    await waitFor(() => expect(within(annotationDialog).getByRole("button", { name: "Done" })).not.toBeDisabled())
    fireEvent.click(within(annotationDialog).getByRole("button", { name: "Done" }))

    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Annotate list_insights-tool-card.png" })).not.toBeInTheDocument())
    expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toHaveAttribute("src", "data:image/png;base64,YW5ub3RhdGVk")
  })

  it("carries the screenshot, prompt, and structured metadata into a new chat and navigates to it on success", async () => {
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,c2NyZWVuc2hvdA==" } as unknown as HTMLCanvasElement)
    mockCreateChat.mockResolvedValue({ message: "Chat created.", redirect_to: "/chats/42", chat: {} } as unknown as chatsApi.ChatCreatedPayload)

    renderHarness()
    await openDialog()
    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toBeInTheDocument())

    fireEvent.change(screen.getByLabelText("What should the assistant know?"), { target: { value: "The icon looks wrong here." } })
    fireEvent.click(screen.getByRole("button", { name: "Discuss" }))

    await waitFor(() => expect(mockCreateChat).toHaveBeenCalledTimes(1))
    const [input] = mockCreateChat.mock.calls[0]
    expect(input.repositoryId).toBeUndefined()
    expect(input.text).toContain("The icon looks wrong here.")
    expect(input.text).toContain('"selected_example_id": "two_open"')
    expect(input.text).toContain('"selected_viewport_preset": "desktop"')
    expect(input.text).toContain(`"catalog_deep_link": "${deepLink}"`)
    expect(input.attachments).toEqual([
      { name: "list_insights-tool-card.png", mimeType: "image/png", dataUrl: "data:image/png;base64,c2NyZWVuc2hvdA==" }
    ])

    await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith("/chats/42"))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("still lets the operator start a chat without an attachment when capture failed", async () => {
    mockHtml2canvas.mockRejectedValue(new Error("tainted canvas"))
    mockCreateChat.mockResolvedValue({ message: "Chat created.", redirect_to: "/chats/7", chat: {} } as unknown as chatsApi.ChatCreatedPayload)

    renderHarness()
    await openDialog()
    await screen.findByText("Couldn't capture a screenshot of this card. You can still start the chat without one — the metadata below is still included.")

    fireEvent.click(screen.getByRole("button", { name: "Discuss" }))

    await waitFor(() => expect(mockCreateChat).toHaveBeenCalledTimes(1))
    const [input] = mockCreateChat.mock.calls[0]
    expect(input.attachments).toEqual([])
  })

  it("shows a clear inline error when starting the chat fails, without closing the dialog", async () => {
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,c2NyZWVuc2hvdA==" } as unknown as HTMLCanvasElement)
    mockCreateChat.mockRejectedValue(new Error("boom"))

    renderHarness()
    await openDialog()
    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toBeInTheDocument())

    fireEvent.click(screen.getByRole("button", { name: "Discuss" }))

    await screen.findByText("Couldn't start a new chat. Please try again.")
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(mockNavigate).not.toHaveBeenCalled()
  })

  it("creates a job directly with the screenshot and prompt, bypassing chat, and navigates to it on success", async () => {
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,c2NyZWVuc2hvdA==" } as unknown as HTMLCanvasElement)
    mockCreateToolCardJob.mockResolvedValue({
      message: "Job created.",
      redirect_to: "/jobs/99",
      job: { id: 99, job_path: "/jobs/99" }
    })

    renderHarness()
    await openDialog()
    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toBeInTheDocument())

    fireEvent.change(screen.getByLabelText("What should the assistant know?"), { target: { value: "The icon looks wrong here." } })
    fireEvent.click(screen.getByRole("button", { name: "Create Job" }))

    await waitFor(() => expect(mockCreateToolCardJob).toHaveBeenCalledTimes(1))
    const [input] = mockCreateToolCardJob.mock.calls[0]
    expect(input.prompt).toContain("The icon looks wrong here.")
    expect(input.prompt).toContain('"selected_example_id": "two_open"')
    expect(input.screenshot).toEqual({ name: "list_insights-tool-card.png", mimeType: "image/png", dataUrl: "data:image/png;base64,c2NyZWVuc2hvdA==" })
    expect(mockCreateChat).not.toHaveBeenCalled()

    await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith("/jobs/99"))
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  })

  it("shows a clear inline error when creating a job fails, without closing the dialog", async () => {
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,c2NyZWVuc2hvdA==" } as unknown as HTMLCanvasElement)
    mockCreateToolCardJob.mockRejectedValue(new Error("boom"))

    renderHarness()
    await openDialog()
    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toBeInTheDocument())

    fireEvent.change(screen.getByLabelText("What should the assistant know?"), { target: { value: "The icon looks wrong here." } })
    fireEvent.click(screen.getByRole("button", { name: "Create Job" }))

    await screen.findByText("Couldn't create a job. Please try again.")
    expect(screen.getByRole("dialog")).toBeInTheDocument()
    expect(mockNavigate).not.toHaveBeenCalled()
  })

  it("disables Create Job until the operator writes a prompt, since it dispatches an agent immediately with no review step", async () => {
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,c2NyZWVuc2hvdA==" } as unknown as HTMLCanvasElement)

    renderHarness()
    await openDialog()
    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the List insights card" })).toBeInTheDocument())

    const createJobButton = screen.getByRole("button", { name: "Create Job" })
    expect(createJobButton).toBeDisabled()

    fireEvent.click(createJobButton)
    expect(mockCreateToolCardJob).not.toHaveBeenCalled()

    fireEvent.change(screen.getByLabelText("What should the assistant know?"), { target: { value: "Now there's a real prompt." } })
    expect(createJobButton).not.toBeDisabled()
  })
})

// Mirrors ImageAnnotationModal.test.tsx's canvas/Image mocking so the real
// shared annotation tool can mount and finish inside this suite instead of
// being stubbed out -- an actual integration of the reused component, not a
// re-implementation of its behavior.
function setUpAnnotationCanvasMocks() {
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockImplementation(function getContext(this: HTMLCanvasElement) {
    const canvas = this as HTMLCanvasElement & { __mockContext?: CanvasRenderingContext2D }
    if (!canvas.__mockContext) {
      canvas.__mockContext = {
        clearRect: vi.fn(), beginPath: vi.fn(), rect: vi.fn(), stroke: vi.fn(), fill: vi.fn(),
        ellipse: vi.fn(), moveTo: vi.fn(), lineTo: vi.fn(), fillText: vi.fn(), measureText: vi.fn().mockReturnValue({ width: 10 }),
        drawImage: vi.fn(), setLineDash: vi.fn(), save: vi.fn(), restore: vi.fn()
      } as unknown as CanvasRenderingContext2D
    }
    return canvas.__mockContext
  })

  vi.spyOn(HTMLCanvasElement.prototype, "toDataURL").mockReturnValue("data:image/png;base64,YW5ub3RhdGVk")
  vi.spyOn(HTMLCanvasElement.prototype, "getBoundingClientRect").mockReturnValue({
    bottom: 80, height: 80, left: 0, right: 100, top: 0, width: 100, x: 0, y: 0, toJSON: () => ({})
  })
  Object.defineProperty(HTMLCanvasElement.prototype, "offsetWidth", { configurable: true, value: 100 })
  Object.defineProperty(HTMLCanvasElement.prototype, "offsetHeight", { configurable: true, value: 80 })

  Object.defineProperty(globalThis, "Image", {
    configurable: true,
    writable: true,
    value: class MockImage {
      naturalWidth = 100
      naturalHeight = 80
      width = 100
      height = 80
      onload: (() => void) | null = null
      set src(_value: string) { this.onload?.() }
    }
  })
}
