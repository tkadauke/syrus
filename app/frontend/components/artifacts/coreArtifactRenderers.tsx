import type { TypedArtifact, ImageDiffPayload, BeforeAfterVisualDiffPayload, BeforeAfterVisualImage } from "../../api/artifacts"
import { useT } from "../../hooks/useT"
import type { ArtifactRendererDefinition, ArtifactRendererExample } from "../../pluginArtifactRenderers"

// Bare definition plus its example fixtures, colocated the same way a
// plugin renderer module colocates `default` and `examples` -- core
// entries just declare both in one object instead of two module exports.
export type CoreArtifactRendererEntry = ArtifactRendererDefinition & { examples: ArtifactRendererExample[] }

// Core-owned renderer_type definitions -- the "core renderers" half of the
// artifact renderer registry contract (see artifactRendererRegistry.ts).
// These ship with core rather than a plugin, so they're registered here
// directly instead of being discovered by directory convention the way
// plugin renderers are (see pluginArtifactRenderers.tsx).

// Not a real backend renderer_type -- the marker artifactRendererRegistry.ts
// falls back to for a null/unregistered renderer_type, or when a
// renderer's own render() throws. Registered as a normal entry (rather than
// a special case) so the fallback is representable in the catalog like any
// other renderer, per the Epic's "fallback renderers" requirement.
export const RAW_JSON_RENDERER_TYPE = "raw_json"

function DataTableBody({ payload }: { payload: Record<string, unknown> }) {
  const headers = Array.isArray(payload.headers) ? payload.headers as string[] : []
  const rows = Array.isArray(payload.rows) ? payload.rows as unknown[][] : []

  if (headers.length === 0 && rows.length === 0) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <div className="overflow-x-auto">
      <table className="w-full border-collapse text-xs">
        {headers.length > 0 ? (
          <thead>
            <tr>
              {headers.map((h, i) => (
                <th className="border border-gray-200 bg-gray-100 px-2 py-1.5 text-left font-semibold text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" key={i}>{String(h)}</th>
              ))}
            </tr>
          </thead>
        ) : null}
        <tbody>
          {rows.map((row, ri) => (
            <tr className="even:bg-gray-50 dark:even:bg-gray-800/50" key={ri}>
              {(Array.isArray(row) ? row : [row]).map((cell, ci) => (
                <td className="border border-gray-200 px-2 py-1 text-gray-800 dark:border-gray-700 dark:text-gray-200" key={ci}>{String(cell ?? "")}</td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function BeforeAfterDiffBody({ payload }: { payload: Record<string, unknown> }) {
  const { t } = useT("jobs")
  const before = typeof payload.before === "string" ? payload.before : null
  const after = typeof payload.after === "string" ? payload.after : null

  if (before === null && after === null) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <div className="grid min-w-0 gap-3 lg:grid-cols-2">
      <div className="min-w-0">
        <p className="mb-1 text-xs font-medium text-gray-500 dark:text-gray-400">{t("artifact_diff_before")}</p>
        <pre className="overflow-x-auto rounded border border-gray-200 bg-gray-50 p-3 text-xs text-gray-800 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200">{before ?? "(empty)"}</pre>
      </div>
      <div className="min-w-0">
        <p className="mb-1 text-xs font-medium text-gray-500 dark:text-gray-400">{t("artifact_diff_after")}</p>
        <pre className="overflow-x-auto rounded border border-gray-200 bg-gray-50 p-3 text-xs text-gray-800 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200">{after ?? "(empty)"}</pre>
      </div>
    </div>
  )
}

function ImageDiffBody({ payload, title }: { payload: ImageDiffPayload; title: string }) {
  if (!payload.image_url) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <a href={payload.image_url} target="_blank" rel="noreferrer">
      <img src={payload.image_url} alt={title} className="max-w-full rounded border border-gray-200" />
    </a>
  )
}

function BeforeAfterVisualDiffBody({ payload }: { payload: BeforeAfterVisualDiffPayload }) {
  const pairs = Array.isArray(payload.pairs) ? payload.pairs : []
  if (pairs.length === 0) {
    return <RawArtifactBody payload={payload} />
  }

  return (
    <div className="space-y-4">
      {pairs.map((pair, index) => (
        <div className="space-y-2" key={`${pair.title || "visual"}-${index}`}>
          <div className="text-xs font-semibold text-gray-700">{pair.title || `Screenshot ${index + 1}`}</div>
          <div className="grid gap-3 md:grid-cols-2">
            <VisualPane label="Merge-base / before" image={pair.before} />
            <VisualPane label="PR / after" image={pair.after} />
          </div>
        </div>
      ))}
    </div>
  )
}

function VisualPane({ label, image }: { label: string; image: BeforeAfterVisualImage }) {
  if (!image?.image_url) return null

  return (
    <div>
      <div className="mb-1 text-xs font-medium text-gray-500">{label}</div>
      <a href={image.image_url} target="_blank" rel="noreferrer">
        <img src={image.image_url} alt={`${label}: ${image.title || "screenshot"}`} className="max-w-full rounded border border-gray-200" />
      </a>
    </div>
  )
}

export function RawArtifactBody({ payload }: { payload: unknown }) {
  return (
    <pre className="overflow-x-auto rounded bg-gray-50 p-3 text-xs text-gray-700">
      {JSON.stringify(payload, null, 2)}
    </pre>
  )
}

export const coreArtifactRendererEntries: CoreArtifactRendererEntry[] = [
  {
    rendererType: "image_diff",
    // Free-form agent-chosen `type` (see SyrusMcp::SubmitVisualArtifactTool)
    // -- no fixed canonical value.
    artifactTypes: [],
    displayLabel: "Image",
    description: "Renders a single stored screenshot image, linked out to the full-size original.",
    supportedPayloadShape: "{ image_url: string }",
    render: (artifact) => <ImageDiffBody payload={artifact.payload as ImageDiffPayload} title={artifact.title} />,
    examples: [
      {
        id: "screenshot",
        label: "Screenshot",
        artifact: {
          type: "visual_review_screenshot",
          title: "Homepage after fix",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "image_diff",
          payload: { image_url: "https://example.com/screenshots/homepage-after.png" }
        }
      },
      {
        id: "missing_image_url",
        label: "Malformed: missing image_url",
        description: "Falls back to the raw JSON renderer when the payload has no image_url.",
        expectedFallback: true,
        artifact: {
          type: "visual_review_screenshot",
          title: "Broken screenshot artifact",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "image_diff",
          payload: {}
        }
      }
    ]
  },
  {
    rendererType: "before_after_visual_diff",
    artifactTypes: [ "visual_diff_comparison" ],
    displayLabel: "Before/after visual diff",
    description: "Renders one or more merge-base/PR screenshot pairs side by side.",
    supportedPayloadShape: "{ pairs: Array<{ title?: string; before: { image_url }; after: { image_url } }> }",
    render: (artifact) => <BeforeAfterVisualDiffBody payload={artifact.payload as BeforeAfterVisualDiffPayload} />,
    examples: [
      {
        id: "dashboard_pair",
        label: "Dashboard before/after",
        artifact: {
          type: "visual_diff_comparison",
          title: "Before/after visual comparison",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "before_after_visual_diff",
          payload: {
            pairs: [
              {
                title: "Dashboard",
                before: { image_url: "https://example.com/screenshots/dashboard-before.png", title: "before" },
                after: { image_url: "https://example.com/screenshots/dashboard-after.png", title: "after" }
              }
            ]
          }
        }
      },
      {
        id: "many_pairs",
        label: "Large payload: eight screenshot pairs",
        description: "Stress-tests the layout with more before/after pairs than a typical visual review round produces.",
        artifact: {
          type: "visual_diff_comparison",
          title: "Full-suite visual comparison",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "before_after_visual_diff",
          payload: {
            pairs: Array.from({ length: 8 }, (_, i) => ({
              title: `Screen ${i + 1}`,
              before: { image_url: `https://example.com/screenshots/screen-${i + 1}-before.png`, title: "before" },
              after: { image_url: `https://example.com/screenshots/screen-${i + 1}-after.png`, title: "after" }
            }))
          }
        }
      },
      {
        id: "no_pairs",
        label: "Malformed: no pairs",
        description: "Falls back to the raw JSON renderer when payload.pairs is empty.",
        expectedFallback: true,
        artifact: {
          type: "visual_diff_comparison",
          title: "Empty visual comparison",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "before_after_visual_diff",
          payload: { pairs: [] }
        }
      }
    ]
  },
  {
    rendererType: "data_table",
    // Free-form agent-chosen `type` (submitted via submit_artifact) -- any
    // step can use this renderer_type for any tabular payload.
    artifactTypes: [],
    displayLabel: "Data table",
    description: "Renders headers/rows as an HTML table.",
    supportedPayloadShape: "{ headers?: string[]; rows?: unknown[][] }",
    render: (artifact) => <DataTableBody payload={artifact.payload as Record<string, unknown>} />,
    examples: [
      {
        id: "coverage_summary",
        label: "Coverage summary table",
        artifact: {
          type: "coverage_summary",
          title: "Coverage by file",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "data_table",
          payload: { headers: [ "File", "Lines" ], rows: [ [ "app/models/job.rb", "92%" ], [ "app/models/run.rb", "88%" ] ] }
        }
      },
      {
        id: "empty_table",
        label: "Malformed: no headers or rows",
        description: "Falls back to the raw JSON renderer when both headers and rows are empty.",
        expectedFallback: true,
        artifact: {
          type: "coverage_summary",
          title: "Empty table",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "data_table",
          payload: {}
        }
      },
      {
        id: "large_dataset",
        label: "Large payload: 60-row coverage table",
        description: "Stress-tests the table renderer with a payload larger than a typical coverage summary.",
        artifact: {
          type: "coverage_summary",
          title: "Coverage by file (full repository)",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "data_table",
          payload: {
            headers: [ "File", "Lines", "Branches" ],
            rows: Array.from({ length: 60 }, (_, i) => [ `app/models/example_model_${i}.rb`, `${70 + (i % 30)}%`, `${50 + (i % 40)}%` ])
          }
        }
      }
    ]
  },
  {
    rendererType: "before_after_diff",
    // Free-form agent-chosen `type` (submitted via submit_artifact) -- any
    // step can use this renderer_type for any before/after text payload.
    artifactTypes: [],
    displayLabel: "Before/after text diff",
    description: "Renders a two-column before/after plain-text comparison.",
    supportedPayloadShape: "{ before?: string; after?: string }",
    render: (artifact) => <BeforeAfterDiffBody payload={artifact.payload as Record<string, unknown>} />,
    examples: [
      {
        id: "config_diff",
        label: "Config text diff",
        artifact: {
          type: "config_diff",
          title: "config/app_settings.yml",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "before_after_diff",
          payload: { before: "max_retries: 1", after: "max_retries: 3" }
        }
      },
      {
        id: "large_diff",
        label: "Large payload: 80-line config rewrite",
        description: "Stress-tests the two-column renderer with a payload larger than a typical single-setting tweak.",
        artifact: {
          type: "config_diff",
          title: "config/app_settings.yml (full rewrite)",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "before_after_diff",
          payload: {
            before: Array.from({ length: 80 }, (_, i) => `setting_${i}: ${i}`).join("\n"),
            after: Array.from({ length: 80 }, (_, i) => `setting_${i}: ${i * 2}`).join("\n")
          }
        }
      },
      {
        id: "missing_before_and_after",
        label: "Malformed: missing before and after",
        description: "Falls back to the raw JSON renderer when both before and after are absent.",
        expectedFallback: true,
        artifact: {
          type: "config_diff",
          title: "Empty config diff",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: "before_after_diff",
          payload: {}
        }
      }
    ]
  },
  {
    rendererType: RAW_JSON_RENDERER_TYPE,
    artifactTypes: [],
    displayLabel: "Raw JSON",
    description: "Fallback renderer for a null, unknown, or unrecognized renderer_type: pretty-prints the raw payload.",
    supportedPayloadShape: "any JSON value",
    render: (artifact: TypedArtifact) => <RawArtifactBody payload={artifact.payload} />,
    examples: [
      {
        id: "unrecognized_renderer_type",
        label: "Unrecognized renderer_type",
        artifact: {
          type: "custom_diagnostic_report",
          title: "Custom diagnostic report",
          created_at: "2026-09-01T12:00:00Z",
          renderer_type: null,
          payload: { note: "no registered renderer for this type", severity: "info" }
        }
      }
    ]
  }
]
