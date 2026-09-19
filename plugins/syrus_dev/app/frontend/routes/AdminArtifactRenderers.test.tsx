import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import html2canvasModule from "html2canvas-pro"
import type { ReactElement } from "react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { beforeEach, describe, expect, it, vi } from "vitest"
import * as chatsApi from "@app/api/chats"
import type { ArtifactRendererEntry } from "@app/artifactRendererRegistry"
import {
  AdminArtifactRenderers,
  ArtifactCatalogEntry,
  buildArtifactRendererFeedbackMetadata,
  buildArtifactRendererFeedbackPrompt,
  payloadSummary,
  type ArtifactRendererFeedbackMetadata
} from "./AdminArtifactRenderers"

const { mockNavigate } = vi.hoisted(() => ({ mockNavigate: vi.fn() }))

vi.mock("react-router-dom", async (importOriginal) => {
  const actual = await importOriginal<typeof import("react-router-dom")>()
  return { ...actual, useNavigate: () => mockNavigate }
})

vi.mock("@app/api/chats", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@app/api/chats")>()
  return { ...actual, createChat: vi.fn() }
})

vi.mock("html2canvas-pro", () => ({
  default: vi.fn()
}))

const mockCreateChat = vi.mocked(chatsApi.createChat)
const mockHtml2canvas = vi.mocked(html2canvasModule)

function fakeT(key: string, options?: Record<string, unknown>): string {
  if (key === "artifact_renderers.payload_summary_empty") return "empty"
  if (key === "artifact_renderers.payload_summary_empty_object") return "object (no fields)"
  if (key === "artifact_renderers.payload_summary_array") return `array (${options?.count} item(s))`
  if (key === "artifact_renderers.payload_summary_object") return `object (${options?.count} field(s): ${options?.fields})`
  return key
}

describe("payloadSummary", () => {
  it("summarizes null/undefined, empty object, array, and populated object payloads", () => {
    expect(payloadSummary(null, fakeT)).toBe("empty")
    expect(payloadSummary(undefined, fakeT)).toBe("empty")
    expect(payloadSummary({}, fakeT)).toBe("object (no fields)")
    expect(payloadSummary([ 1, 2, 3 ], fakeT)).toBe("array (3 item(s))")
    expect(payloadSummary({ headers: [], rows: [] }, fakeT)).toBe("object (2 field(s): headers, rows)")
  })
})

describe("artifact renderer feedback metadata", () => {
  it("carries renderer, artifact, viewport, deep-link, annotation, metadata, and full payload context", () => {
    const artifact = provenanceEntry.examples[0].artifact
    const shapes = [ { id: "s1", kind: "text" as const, x: 1, y: 2, value: "check table", color: "#ef4444" } ]

    const metadata = buildArtifactRendererFeedbackMetadata(
      provenanceEntry,
      artifact,
      "with_provenance",
      "tablet",
      "https://syrus.test/admin/artifact_renderers?renderer=synthetic_provenance&example=with_provenance#renderer-synthetic_provenance",
      shapes
    )

    expect(metadata).toEqual<ArtifactRendererFeedbackMetadata>({
      catalog_deep_link: "https://syrus.test/admin/artifact_renderers?renderer=synthetic_provenance&example=with_provenance#renderer-synthetic_provenance",
      renderer_type: "synthetic_provenance",
      display_label: "Synthetic Provenance Renderer",
      artifact_type: "synthetic_artifact",
      owner_type: "core",
      plugin_name: null,
      fallback_only: false,
      selected_example_id: "with_provenance",
      selected_viewport_preset: "tablet",
      artifact_metadata: {
        type: "synthetic_artifact",
        title: "Synthetic title",
        created_at: "2026-09-02T00:00:00Z",
        renderer_type: null,
        workflow_id: 555,
        run_id: 777,
        step_id: 888,
        trigger_kind: "initial",
        base_sha: "abc123",
        head_sha: "def456",
        diff_review_version_id: 42
      },
      selected_payload: { a: 1, b: 2, c: 3 },
      full_artifact: artifact,
      annotations: shapes
    })
  })

  it("builds a readable prompt before the raw JSON block", () => {
    const metadata = buildArtifactRendererFeedbackMetadata(provenanceEntry, provenanceEntry.examples[0].artifact, "with_provenance", "desktop", "https://syrus.test/admin/artifact_renderers")
    const text = buildArtifactRendererFeedbackPrompt("The layout breaks on mobile.", metadata)

    expect(text.startsWith("The layout breaks on mobile.")).toBe(true)
    expect(text).toContain("Renderer: Synthetic Provenance Renderer (`synthetic_provenance`)")
    expect(text).toContain("Artifact type: synthetic_artifact")
    expect(text).toContain("```json")
    expect(text).toContain(JSON.stringify(metadata, null, 2))
  })
})

describe("AdminArtifactRenderers", () => {
  beforeEach(() => {
    mockNavigate.mockClear()
    mockCreateChat.mockReset()
    mockHtml2canvas.mockReset()
  })

  it("renders the heading, filter bar, and an empty state when nothing matches", () => {
    renderRoute("/admin/artifact_renderers?artifact_type=zzz_does_not_exist_zzz")

    expect(screen.getByRole("heading", { name: "Artifact Renderer Catalog" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
    expect(screen.getByText("No renderers match these filters.")).toBeInTheDocument()
  })

  it("filters the catalog by artifact type", () => {
    renderRoute("/admin/artifact_renderers?artifact_type=rails_schema_erd")

    expect(screen.getByRole("region", { name: "Rails schema ERD" })).toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Rails migration diff" })).not.toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Data table" })).not.toBeInTheDocument()
  })

  it("matches an entry when renderer type, owner, plugin name, and status filters all agree", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=erd_diagram&owner_type=plugin&plugin_name=rails&status=plugin")

    expect(screen.getByRole("region", { name: "Rails schema ERD" })).toBeInTheDocument()
  })

  it("excludes an entry once a combined filter field no longer matches it", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=erd_diagram&owner_type=core")

    expect(screen.queryByRole("region", { name: "Rails schema ERD" })).not.toBeInTheDocument()
    expect(screen.getByText("No renderers match these filters.")).toBeInTheDocument()
  })

  it("filters the catalog by example label", () => {
    renderRoute("/admin/artifact_renderers?example_label=large")

    expect(screen.getByRole("region", { name: "Data table" })).toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Image" })).not.toBeInTheDocument()
  })

  it("isolates the raw JSON fallback renderer via the status filter", () => {
    renderRoute("/admin/artifact_renderers?status=fallback")

    expect(screen.getByRole("region", { name: "Raw JSON" })).toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Image" })).not.toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Rails schema ERD" })).not.toBeInTheDocument()
  })

  it("filters the catalog by payload shape", () => {
    const params = new URLSearchParams({ payload_shape: "any JSON value" })
    renderRoute(`/admin/artifact_renderers?${params.toString()}`)

    expect(screen.getByRole("region", { name: "Raw JSON" })).toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Data table" })).not.toBeInTheDocument()
  })

  it("renders a plugin-provided renderer's example through the real ArtifactBody path", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=erd_diagram")

    const region = screen.getByRole("region", { name: "Rails schema ERD" })
    expect(within(region).getAllByText("plugin · rails").length).toBeGreaterThanOrEqual(2)
    expect(within(region).getByText("users")).toBeInTheDocument()
    expect(within(region).getByText("accounts")).toBeInTheDocument()
  })

  it("renders a second plugin-provided renderer through the same real ArtifactBody path", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=migration_diff")

    const region = screen.getByRole("region", { name: "Rails migration diff" })
    expect(within(region).getAllByText("plugin · rails").length).toBeGreaterThanOrEqual(2)
    expect(within(region).getByText("AddEmailToUsers")).toBeInTheDocument()
  })

  it("renders a core renderer with multiple examples and lets an operator switch between them", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=data_table")

    const region = screen.getByRole("region", { name: "Data table" })
    expect(within(region).getByText("92%")).toBeInTheDocument()

    fireEvent.click(within(region).getByRole("tab", { name: "Malformed: no headers or rows" }))

    expect(within(region).queryByText("92%")).not.toBeInTheDocument()
    expect(within(region).getByText("Falls back to the raw JSON renderer when both headers and rows are empty.")).toBeInTheDocument()
  })

  it("keeps a malformed, expected-fallback example visible and renders its raw JSON fallback body", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=image_diff")

    const region = screen.getByRole("region", { name: "Image" })
    fireEvent.click(within(region).getByRole("tab", { name: "Malformed: missing image_url" }))

    expect(within(region).getByText("Falls back to the raw JSON renderer when the payload has no image_url.")).toBeInTheDocument()
    expect(within(region).getByText("Expected to degrade to a fallback body")).toBeInTheDocument()
    expect(within(region).getByText("{}")).toBeInTheDocument()
  })

  it("deep-links directly to a specific renderer and example", () => {
    renderRoute("/admin/artifact_renderers?renderer=data_table&example=large_dataset")

    const region = screen.getByRole("region", { name: "Data table" })
    expect(within(region).getByRole("tab", { name: "Large payload: 60-row coverage table", selected: true })).toBeInTheDocument()
  })

  it("defaults the preview viewport to desktop and lets an operator switch presets", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=data_table")

    const switcher = screen.getByRole("tablist", { name: "Preview viewport" })
    expect(within(switcher).getByRole("tab", { name: "Desktop (1280px)", selected: true })).toBeInTheDocument()

    fireEvent.click(within(switcher).getByRole("tab", { name: "Phone (390px)" }))

    expect(within(switcher).getByRole("tab", { name: "Phone (390px)", selected: true })).toBeInTheDocument()
  })

  it("places a shared 'Discuss this renderer' button next to the rendered preview", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=data_table")

    const region = screen.getByRole("region", { name: "Data table" })
    const discussButton = within(region).getByRole("button", { name: "Discuss this renderer" })
    const preview = within(region).getByLabelText(/Renderer preview constrained to/)

    expect(region).toContainElement(discussButton)
    expect(region).toContainElement(preview)
  })

  it("applies each shared viewport preset's width as an explicit inline width", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=data_table")

    const region = screen.getByRole("region", { name: "Data table" })
    const frame = () => within(region).getByLabelText(/Renderer preview constrained to/)

    expect(frame().style.width).toBe("1280px")

    fireEvent.click(screen.getByRole("tab", { name: "Wide desktop (1600px)" }))
    expect(frame().style.width).toBe("1600px")
    expect(frame().style.maxWidth).toBe("")
  })

  it("carries screenshot, prompt, deep link, renderer metadata, artifact metadata, and full payload into a new chat", async () => {
    mockHtml2canvas.mockResolvedValue({ toDataURL: () => "data:image/png;base64,YXJ0aWZhY3Q=" } as unknown as HTMLCanvasElement)
    mockCreateChat.mockResolvedValue({ message: "Chat created.", redirect_to: "/chats/99", chat: {} } as unknown as chatsApi.ChatCreatedPayload)

    renderRoute("/admin/artifact_renderers?renderer_type=erd_diagram&viewport=phone")

    const region = screen.getByRole("region", { name: "Rails schema ERD" })
    fireEvent.click(within(region).getByRole("button", { name: "Discuss this renderer" }))

    await waitFor(() => expect(screen.getByRole("img", { name: "Screenshot of the Rails schema ERD renderer" })).toHaveAttribute("src", "data:image/png;base64,YXJ0aWZhY3Q="))
    expect(mockHtml2canvas.mock.calls[0][0]).toBe(within(region).getByLabelText("Renderer preview constrained to 390px"))

    fireEvent.change(screen.getByLabelText("What should the assistant know?"), { target: { value: "The schema labels crowd each other." } })
    fireEvent.click(screen.getByRole("button", { name: "Open chat" }))

    await waitFor(() => expect(mockCreateChat).toHaveBeenCalledTimes(1))
    const [input] = mockCreateChat.mock.calls[0]
    expect(input.text).toContain("The schema labels crowd each other.")
    expect(input.text).toContain('"renderer_type": "erd_diagram"')
    expect(input.text).toContain('"artifact_type": "rails_schema_erd"')
    expect(input.text).toContain('"owner_type": "plugin"')
    expect(input.text).toContain('"plugin_name": "rails"')
    expect(input.text).toContain('"selected_viewport_preset": "phone"')
    expect(input.text).toContain('"selected_payload"')
    expect(input.text).toContain('"full_artifact"')
    expect(input.text).toContain('"catalog_deep_link"')
    expect(input.attachments).toEqual([
      { name: "erd_diagram-artifact-renderer.png", mimeType: "image/png", dataUrl: "data:image/png;base64,YXJ0aWZhY3Q=" }
    ])
    await waitFor(() => expect(mockNavigate).toHaveBeenCalledWith("/chats/99"))
  })

  it("keeps raw artifact metadata available when screenshot capture fails", async () => {
    mockHtml2canvas.mockRejectedValue(new Error("tainted canvas"))
    mockCreateChat.mockResolvedValue({ message: "Chat created.", redirect_to: "/chats/100", chat: {} } as unknown as chatsApi.ChatCreatedPayload)

    renderRoute("/admin/artifact_renderers?renderer_type=erd_diagram")

    const region = screen.getByRole("region", { name: "Rails schema ERD" })
    fireEvent.click(within(region).getByRole("button", { name: "Discuss this renderer" }))

    await screen.findByText("Couldn't capture a screenshot of this renderer. You can still start the chat without one — the metadata below is still included.")
    fireEvent.click(screen.getByText("Raw payload metadata"))
    expect(screen.getByText(/"renderer_type": "erd_diagram"/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Open chat" }))
    await waitFor(() => expect(mockCreateChat).toHaveBeenCalledTimes(1))
    expect(mockCreateChat.mock.calls[0][0].attachments).toEqual([])
  })

  it("shows title, type, renderer type, owner, created-at, and a payload summary around the preview", () => {
    renderRoute("/admin/artifact_renderers?renderer_type=erd_diagram")

    const region = screen.getByRole("region", { name: "Rails schema ERD" })
    expect(within(region).getByText("Schema ERD")).toBeInTheDocument()
    expect(within(region).getByText("rails_schema_erd")).toBeInTheDocument()
    expect(within(region).getByText("2026-09-01T12:00:00Z")).toBeInTheDocument()
    expect(within(region).getByText("object (1 field(s): tables)")).toBeInTheDocument()
  })
})

describe("ArtifactCatalogEntry (synthetic entries not shipped in the real registry)", () => {
  it("keeps a fallback-only, example-less renderer visible instead of hiding it", () => {
    renderEntry(<ArtifactCatalogEntry entry={fallbackOnlyEntry} previewWidth={1280} />)

    const region = screen.getByRole("region", { name: "Synthetic Fallback-Only Renderer" })
    expect(within(region).getByText("plugin · example_plugin")).toBeInTheDocument()
    expect(within(region).getByText("Fallback-only (no examples)")).toBeInTheDocument()
    expect(within(region).getByText("No example fixtures registered for this renderer yet.")).toBeInTheDocument()
  })

  it("shows provenance fields only when present on the artifact, alongside a payload summary", () => {
    renderEntry(<ArtifactCatalogEntry entry={provenanceEntry} previewWidth={1280} />)

    const region = screen.getByRole("region", { name: "Synthetic Provenance Renderer" })
    expect(within(region).getByText("555")).toBeInTheDocument()
    expect(within(region).getByText("777")).toBeInTheDocument()
    expect(within(region).getByText("888")).toBeInTheDocument()
    expect(within(region).getByText("initial")).toBeInTheDocument()
    expect(within(region).getByText("abc123")).toBeInTheDocument()
    expect(within(region).getByText("def456")).toBeInTheDocument()
    expect(within(region).getByText("42")).toBeInTheDocument()
    expect(within(region).getByText("object (3 field(s): a, b, c)")).toBeInTheDocument()
  })

  it("omits provenance fields entirely when the artifact carries none", () => {
    renderEntry(<ArtifactCatalogEntry entry={noProvenanceEntry} previewWidth={1280} />)

    const region = screen.getByRole("region", { name: "Synthetic No-Provenance Renderer" })
    expect(within(region).queryByText("Workflow")).not.toBeInTheDocument()
    expect(within(region).queryByText("Trigger kind")).not.toBeInTheDocument()
    expect(within(region).queryByText("Base SHA")).not.toBeInTheDocument()
  })
})

const fallbackOnlyEntry: ArtifactRendererEntry = {
  rendererType: "synthetic_fallback_only",
  artifactTypes: [],
  ownerType: "plugin",
  pluginName: "example_plugin",
  displayLabel: "Synthetic Fallback-Only Renderer",
  description: "A renderer with no shipped examples.",
  supportedPayloadShape: "{}",
  render: () => null,
  examples: [],
  fallbackOnly: true
}

const provenanceEntry: ArtifactRendererEntry = {
  rendererType: "synthetic_provenance",
  artifactTypes: [],
  ownerType: "core",
  pluginName: null,
  displayLabel: "Synthetic Provenance Renderer",
  description: "",
  supportedPayloadShape: "any JSON value",
  render: () => null,
  examples: [
    {
      id: "with_provenance",
      label: "With provenance",
      artifact: {
        type: "synthetic_artifact",
        title: "Synthetic title",
        created_at: "2026-09-02T00:00:00Z",
        renderer_type: null,
        payload: { a: 1, b: 2, c: 3 },
        workflow_id: 555,
        run_id: 777,
        step_id: 888,
        trigger_kind: "initial",
        base_sha: "abc123",
        head_sha: "def456",
        diff_review_version_id: 42
      }
    }
  ]
}

const noProvenanceEntry: ArtifactRendererEntry = {
  rendererType: "synthetic_no_provenance",
  artifactTypes: [],
  ownerType: "core",
  pluginName: null,
  displayLabel: "Synthetic No-Provenance Renderer",
  description: "",
  supportedPayloadShape: "any JSON value",
  render: () => null,
  examples: [
    {
      id: "bare",
      label: "Bare",
      artifact: {
        type: "synthetic_artifact",
        title: "Synthetic title",
        created_at: "2026-09-02T00:00:00Z",
        renderer_type: null,
        payload: {}
      }
    }
  ]
}

function renderRoute(initialEntry = "/admin/artifact_renderers") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ initialEntry ]}>
        <Routes>
          <Route element={<AdminArtifactRenderers />} path="/admin/artifact_renderers" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function renderEntry(element: ReactElement) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        {element}
      </MemoryRouter>
    </QueryClientProvider>
  )
}
