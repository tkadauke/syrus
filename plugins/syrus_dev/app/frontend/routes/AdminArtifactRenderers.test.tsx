import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { ArtifactRendererEntry } from "@app/artifactRendererRegistry"
import { AdminArtifactRenderers, ArtifactCatalogEntry, payloadSummary } from "./AdminArtifactRenderers"

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

describe("AdminArtifactRenderers", () => {
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
    render(<ArtifactCatalogEntry entry={fallbackOnlyEntry} previewWidth={1280} />)

    const region = screen.getByRole("region", { name: "Synthetic Fallback-Only Renderer" })
    expect(within(region).getByText("plugin · example_plugin")).toBeInTheDocument()
    expect(within(region).getByText("Fallback-only (no examples)")).toBeInTheDocument()
    expect(within(region).getByText("No example fixtures registered for this renderer yet.")).toBeInTheDocument()
  })

  it("shows provenance fields only when present on the artifact, alongside a payload summary", () => {
    render(<ArtifactCatalogEntry entry={provenanceEntry} previewWidth={1280} />)

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
    render(<ArtifactCatalogEntry entry={noProvenanceEntry} previewWidth={1280} />)

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
  return render(
    <MemoryRouter initialEntries={[ initialEntry ]}>
      <Routes>
        <Route element={<AdminArtifactRenderers />} path="/admin/artifact_renderers" />
      </Routes>
    </MemoryRouter>
  )
}
