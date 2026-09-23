import { useCallback, useMemo, useRef, useState, type RefObject } from "react"
import { useLocation } from "react-router-dom"
import type { TypedArtifact } from "@app/api/artifacts"
import { allArtifactRendererEntries, type ArtifactRendererEntry } from "@app/artifactRendererRegistry"
import { FilterBar, type FilterSchemaField } from "@app/components/FilterBar"
import { ArtifactBody } from "@app/components/artifacts/TypedArtifactPanel"
import type { Shape } from "@app/components/ImageAnnotationModal"
import { RAW_JSON_RENDERER_TYPE } from "@app/components/artifacts/coreArtifactRenderers"
import { Badge, DescriptionList, Page, PanelMessage, Section, Text, type SemanticTone } from "@app/components/ui"
import { useCopyToClipboard } from "@app/hooks/useCopyToClipboard"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { CatalogExampleSelector } from "../catalog/CatalogExampleSelector"
import { CatalogFeedbackDialog } from "../catalog/CatalogFeedbackDialog"
import { catalogAnchorId, useCatalogDeepLinkScroll } from "../catalog/catalogDeepLink"
import { buildCatalogFilterLink, catalogFilterTreeFromSearch, catalogFiltersFromSearch } from "../catalog/catalogFilterLink"
import { CatalogViewportFrame, CatalogViewportSwitcher, viewportPresetFromSearch, type ViewportPresetId } from "../catalog/catalogViewport"

// The Artifact Renderer Catalog: every registered typed-artifact renderer
// (core, plugin-owned, and the raw JSON fallback -- see
// artifactRendererRegistry.ts), reviewable from its own synthetic example
// fixtures without digging through a real workflow artifact. Each example
// renders through the exact same ArtifactBody/TypedArtifactPanel path real
// Job detail artifact surfaces use, so unknown/malformed-payload fallback
// behavior is never re-implemented here -- only composed from the registry
// + the real rendering path. Mirrors AdminToolCards.tsx's Tool Card
// Catalog; both pages share catalog layout, filter wiring, example
// selection, viewport framing, and deep-link primitives from `../catalog`.
//
// This page reads a purely client-side, compiled registry -- there is no
// backend endpoint or persisted filter state, so filtering happens in this
// file against the in-memory entry list rather than through Filters::Subject
// (which exists for ActiveRecord-backed collections).

type RendererStatus = "core" | "plugin" | "fallback"

const FILTER_FIELDS = ["artifact_type", "renderer_type", "owner_type", "plugin_name", "example_label", "status", "payload_shape"] as const
type CatalogFilterField = (typeof FILTER_FIELDS)[number]
const TEXT_FILTER_FIELDS: readonly CatalogFilterField[] = ["artifact_type", "example_label"]

const OWNER_TYPE_OPTIONS = [
  { value: "core", label: "Core" },
  { value: "plugin", label: "Plugin" }
]

// A dedicated status option beyond plain owner type: "fallback" isolates
// the single raw_json entry every unregistered/malformed artifact degrades
// to, which is conceptually distinct from an ordinary core renderer even
// though it happens to ship with core too.
const STATUS_OPTIONS = [
  { value: "core", label: "Core" },
  { value: "plugin", label: "Plugin" },
  { value: "fallback", label: "Fallback" }
]

function statusFor(entry: ArtifactRendererEntry): RendererStatus {
  if (entry.rendererType === RAW_JSON_RENDERER_TYPE) return "fallback"
  return entry.ownerType === "plugin" ? "plugin" : "core"
}

function ownerTone(ownerType: ArtifactRendererEntry["ownerType"]): SemanticTone {
  return ownerType === "plugin" ? "info" : "neutral"
}

export function anchorId(rendererType: string) {
  return catalogAnchorId("renderer", rendererType)
}

function artifactTypeHaystack(entry: ArtifactRendererEntry): string {
  return entry.artifactTypes.length > 0 ? entry.artifactTypes.join(" ") : "generic"
}

function matchesFilters(entry: ArtifactRendererEntry, filters: Partial<Record<CatalogFilterField, string>>) {
  if (filters.artifact_type && !artifactTypeHaystack(entry).toLowerCase().includes(filters.artifact_type.toLowerCase())) return false
  if (filters.renderer_type && entry.rendererType !== filters.renderer_type) return false
  if (filters.owner_type && entry.ownerType !== filters.owner_type) return false
  if (filters.plugin_name && entry.pluginName !== filters.plugin_name) return false
  if (filters.example_label) {
    const needle = filters.example_label.toLowerCase()
    const matches = entry.examples.some((example) => example.label.toLowerCase().includes(needle) || example.id.toLowerCase().includes(needle))
    if (!matches) return false
  }
  if (filters.status && statusFor(entry) !== filters.status) return false
  if (filters.payload_shape && entry.supportedPayloadShape !== filters.payload_shape) return false
  return true
}

const catalogFilterLink = buildCatalogFilterLink(FILTER_FIELDS)

export function payloadSummary(payload: unknown, t: (key: string, options?: Record<string, unknown>) => string): string {
  if (payload === null || payload === undefined) return t("artifact_renderers.payload_summary_empty")
  if (Array.isArray(payload)) return t("artifact_renderers.payload_summary_array", { count: payload.length })
  if (typeof payload === "object") {
    const keys = Object.keys(payload as Record<string, unknown>)
    if (keys.length === 0) return t("artifact_renderers.payload_summary_empty_object")
    return t("artifact_renderers.payload_summary_object", { count: keys.length, fields: keys.join(", ") })
  }
  return String(payload)
}

export type ArtifactRendererFeedbackMetadata = {
  catalog_deep_link: string
  renderer_type: string
  display_label: string
  artifact_type: string
  owner_type: ArtifactRendererEntry["ownerType"]
  plugin_name: string | null
  fallback_only: boolean
  selected_example_id: string
  selected_viewport_preset: ViewportPresetId
  artifact_metadata: Omit<TypedArtifact, "payload">
  selected_payload: unknown
  full_artifact: TypedArtifact
  annotations: Shape[]
}

export function buildArtifactRendererFeedbackMetadata(
  entry: ArtifactRendererEntry,
  artifact: TypedArtifact,
  selectedExampleId: string,
  viewportPresetId: ViewportPresetId,
  deepLink: string,
  annotations: Shape[] = []
): ArtifactRendererFeedbackMetadata {
  const { payload: _payload, ...artifactMetadata } = artifact
  return {
    catalog_deep_link: deepLink,
    renderer_type: entry.rendererType,
    display_label: entry.displayLabel,
    artifact_type: artifact.type,
    owner_type: entry.ownerType,
    plugin_name: entry.pluginName,
    fallback_only: Boolean(entry.fallbackOnly),
    selected_example_id: selectedExampleId,
    selected_viewport_preset: viewportPresetId,
    artifact_metadata: artifactMetadata,
    selected_payload: artifact.payload,
    full_artifact: artifact,
    annotations
  }
}

export function buildArtifactRendererFeedbackPrompt(promptText: string, metadata: ArtifactRendererFeedbackMetadata): string {
  const trimmedPrompt = promptText.trim()
  const heading = trimmedPrompt || `Discuss the "${metadata.display_label}" artifact renderer in the Artifact Renderer Catalog.`

  const summary = [
    "---",
    "**Artifact Renderer Context**",
    `- Renderer: ${metadata.display_label} (\`${metadata.renderer_type}\`)`,
    `- Artifact type: ${metadata.artifact_type}`,
    `- Owner: ${metadata.owner_type}${metadata.plugin_name ? ` · ${metadata.plugin_name}` : ""}`,
    `- Example: ${metadata.selected_example_id}`,
    `- Viewport: ${metadata.selected_viewport_preset}`,
    `- Catalog link: ${metadata.catalog_deep_link}`
  ].join("\n")

  const jsonBlock = "```json\n" + JSON.stringify(metadata, null, 2) + "\n```"

  return [heading, summary, jsonBlock].join("\n\n")
}

// Only the provenance fields actually present on this artifact are shown --
// chat-scoped artifacts generally carry none of these (see TypedArtifact).
function provenanceItems(artifact: TypedArtifact, t: (key: string, options?: Record<string, unknown>) => string): Array<[string, string]> {
  const fields: Array<[string, unknown]> = [
    [t("artifact_renderers.meta_workflow_id"), artifact.workflow_id],
    [t("artifact_renderers.meta_run_id"), artifact.run_id],
    [t("artifact_renderers.meta_step_id"), artifact.step_id],
    [t("artifact_renderers.meta_trigger_kind"), artifact.trigger_kind],
    [t("artifact_renderers.meta_base_sha"), artifact.base_sha],
    [t("artifact_renderers.meta_head_sha"), artifact.head_sha],
    [t("artifact_renderers.meta_diff_review_version_id"), artifact.diff_review_version_id]
  ]
  return fields.filter((pair): pair is [string, string | number] => pair[1] !== null && pair[1] !== undefined).map(([label, value]) => [label, String(value)])
}

export function AdminArtifactRenderers() {
  const { t } = useT("syrus_dev")
  usePageTitle(t("artifact_renderers.heading"))
  const location = useLocation()
  const search = location.search

  const allEntries = useMemo(() => allArtifactRendererEntries(), [])

  const rendererTypeOptions = useMemo(() => {
    const names = Array.from(new Set(allEntries.map((entry) => entry.rendererType))).sort()
    return names.map((name) => ({ value: name, label: name }))
  }, [allEntries])

  const pluginNameOptions = useMemo(() => {
    const names = Array.from(new Set(allEntries.flatMap((entry) => (entry.pluginName ? [entry.pluginName] : [])))).sort()
    return names.map((name) => ({ value: name, label: name }))
  }, [allEntries])

  const payloadShapeOptions = useMemo(() => {
    const shapes = Array.from(new Set(allEntries.map((entry) => entry.supportedPayloadShape))).sort()
    return shapes.map((shape) => ({ value: shape, label: shape }))
  }, [allEntries])

  const filterSchema: FilterSchemaField[] = useMemo(
    () => [
      { field: "artifact_type", label: t("artifact_renderers.filter_artifact_type"), bucket: "text", operators: ["contains"], values: [] },
      { field: "renderer_type", label: t("artifact_renderers.filter_renderer_type"), bucket: "select", operators: ["is"], values: rendererTypeOptions },
      { field: "owner_type", label: t("artifact_renderers.filter_owner_type"), bucket: "select", operators: ["is"], values: OWNER_TYPE_OPTIONS },
      { field: "plugin_name", label: t("artifact_renderers.filter_plugin_name"), bucket: "select", operators: ["is"], values: pluginNameOptions },
      { field: "example_label", label: t("artifact_renderers.filter_example_label"), bucket: "text", operators: ["contains"], values: [] },
      { field: "status", label: t("artifact_renderers.filter_status"), bucket: "select", operators: ["is"], values: STATUS_OPTIONS },
      { field: "payload_shape", label: t("artifact_renderers.filter_payload_shape"), bucket: "select", operators: ["is"], values: payloadShapeOptions }
    ],
    [t, rendererTypeOptions, pluginNameOptions, payloadShapeOptions]
  )

  const filters = useMemo(() => catalogFiltersFromSearch(FILTER_FIELDS, search), [search])
  const filterTree = useMemo(() => catalogFilterTreeFromSearch(FILTER_FIELDS, TEXT_FILTER_FIELDS, search), [search])
  const selectedViewport = useMemo(() => viewportPresetFromSearch(search), [search])

  const filteredEntries = useMemo(
    () => allEntries.filter((entry) => matchesFilters(entry, filters)).sort((left, right) => left.rendererType.localeCompare(right.rendererType)),
    [allEntries, filters]
  )

  const params = new URLSearchParams(search)
  const deepLinkRenderer = params.get("renderer")
  const deepLinkExample = params.get("example")

  useCatalogDeepLinkScroll(deepLinkRenderer ? anchorId(deepLinkRenderer) : null, filteredEntries)

  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header>
        <Page.HeadingGroup>
          <Page.Title>{t("artifact_renderers.heading")}</Page.Title>
          <Page.Description>{t("artifact_renderers.description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      <Page.Nav className="space-y-4">
        <FilterBar buildLink={catalogFilterLink} filter={filterTree} filterSchema={filterSchema} pathname={location.pathname} search={search} />

        <div className="flex flex-wrap items-center justify-between gap-2">
          <Text muted variant="caption">
            {t("artifact_renderers.showing", { count: filteredEntries.length, total: allEntries.length })}
          </Text>
          <CatalogViewportSwitcher
            ariaLabel={t("artifact_renderers.viewport_switcher_aria")}
            labelFor={(preset) => t(`artifact_renderers.viewport_${preset.id}`, { width: preset.width })}
            pathname={location.pathname}
            search={search}
            selected={selectedViewport.id}
          />
        </div>
      </Page.Nav>

      {filteredEntries.length === 0 ? (
        <PanelMessage>{t("artifact_renderers.no_match")}</PanelMessage>
      ) : (
        <div className="space-y-4">
          {filteredEntries.map((entry) => (
            <ArtifactCatalogEntry
              entry={entry}
              initialExampleId={entry.rendererType === deepLinkRenderer ? deepLinkExample : null}
              key={entry.rendererType}
              previewWidth={selectedViewport.width}
              viewportPresetId={selectedViewport.id}
            />
          ))}
        </div>
      )}
    </Page.Root>
  )
}

export default AdminArtifactRenderers

export function ArtifactCatalogEntry({
  entry,
  initialExampleId,
  previewWidth,
  viewportPresetId = "desktop"
}: {
  entry: ArtifactRendererEntry
  initialExampleId?: string | null
  previewWidth: number
  viewportPresetId?: ViewportPresetId
}) {
  const { t } = useT("syrus_dev")
  const { copied, copy } = useCopyToClipboard()
  const hasInitialMatch = Boolean(initialExampleId && entry.examples.some((example) => example.id === initialExampleId))
  const [selectedId, setSelectedId] = useState<string | null>(hasInitialMatch ? (initialExampleId as string) : (entry.examples[0]?.id ?? null))
  const id = anchorId(entry.rendererType)
  const headingId = `${id}-heading`
  const previewFrameRef = useRef<HTMLDivElement | null>(null)

  const selectedExample = entry.examples.find((example) => example.id === selectedId) ?? entry.examples[0] ?? null

  function deepLinkFor(exampleId: string) {
    const url = new URL(window.location.href)
    url.searchParams.set("renderer", entry.rendererType)
    url.searchParams.set("example", exampleId)
    url.hash = id
    return url.toString()
  }

  return (
    <Section.Root aria-labelledby={headingId} id={id}>
      <Section.Header>
        <div className="min-w-0">
          <Section.Title id={headingId}>{entry.displayLabel}</Section.Title>
          <Section.Description>
            <code>{entry.rendererType}</code>
            {entry.artifactTypes.length > 0 ? <span> · {t("artifact_renderers.artifact_types", { types: entry.artifactTypes.join(", ") })}</span> : null}
            {entry.description ? <span> · {entry.description}</span> : null}
          </Section.Description>
        </div>
        <Section.Actions>
          <Badge tone={ownerTone(entry.ownerType)}>
            {entry.ownerType}
            {entry.pluginName ? ` · ${entry.pluginName}` : ""}
          </Badge>
          {statusFor(entry) === "fallback" ? <Badge tone="warning">{t("artifact_renderers.status_fallback")}</Badge> : null}
          {entry.fallbackOnly ? <Badge tone="warning">{t("artifact_renderers.fallback_only")}</Badge> : null}
        </Section.Actions>
      </Section.Header>
      <Section.Body className="space-y-3">
        {entry.examples.length === 0 ? (
          <PanelMessage>{t("artifact_renderers.no_examples")}</PanelMessage>
        ) : (
          <>
            <CatalogExampleSelector
              ariaLabel={t("artifact_renderers.example_selector_aria", { renderer: entry.displayLabel })}
              examples={entry.examples.map((example) => ({ id: example.id, label: example.label }))}
              onSelect={setSelectedId}
              selectedId={selectedExample?.id ?? null}
            />

            {selectedExample?.description ? (
              <Text tone="muted" variant="caption">
                {selectedExample.description}
              </Text>
            ) : null}
            {selectedExample?.expectedFallback ? <Badge tone="warning">{t("artifact_renderers.expected_fallback")}</Badge> : null}

            <div className="flex items-center justify-between gap-2">
              {selectedExample ? (
                <ArtifactRendererDiscussButton
                  deepLink={deepLinkFor(selectedExample.id)}
                  entry={entry}
                  exampleId={selectedExample.id}
                  previewRef={previewFrameRef}
                  selectedArtifact={selectedExample.artifact}
                  viewportPresetId={viewportPresetId}
                />
              ) : (
                <span />
              )}
              <button
                className="text-xs text-brand underline hover:no-underline"
                onClick={() => selectedExample && copy(deepLinkFor(selectedExample.id))}
                type="button"
              >
                {copied ? t("artifact_renderers.link_copied") : t("artifact_renderers.copy_link")}
              </button>
            </div>

            {selectedExample ? (
              <div className="grid min-w-0 gap-4 lg:grid-cols-[minmax(0,1fr)_20rem]">
                <CatalogViewportFrame
                  ariaLabel={t("artifact_renderers.viewport_frame_aria", { width: previewWidth })}
                  className="min-w-0"
                  ref={previewFrameRef}
                  width={previewWidth}
                >
                  <ArtifactBody artifact={selectedExample.artifact} />
                </CatalogViewportFrame>
                <ArtifactMetadataPanel artifact={selectedExample.artifact} entry={entry} />
              </div>
            ) : null}
          </>
        )}
      </Section.Body>
    </Section.Root>
  )
}

function ArtifactRendererDiscussButton({
  deepLink,
  entry,
  exampleId,
  previewRef,
  selectedArtifact,
  viewportPresetId
}: {
  deepLink: string
  entry: ArtifactRendererEntry
  exampleId: string
  previewRef: RefObject<HTMLElement | null>
  selectedArtifact: TypedArtifact
  viewportPresetId: ViewportPresetId
}) {
  const { t } = useT("syrus_dev")
  const buildMetadata = useCallback(
    (annotations: Shape[]) => buildArtifactRendererFeedbackMetadata(entry, selectedArtifact, exampleId, viewportPresetId, deepLink, annotations),
    [entry, selectedArtifact, exampleId, viewportPresetId, deepLink]
  )

  return (
    <CatalogFeedbackDialog
      attachmentName={`${entry.rendererType}-artifact-renderer.png`}
      buildMetadata={buildMetadata}
      buildPrompt={buildArtifactRendererFeedbackPrompt}
      copy={{
        trigger: t("artifact_renderers.discuss.trigger"),
        modalAria: t("artifact_renderers.discuss.modal_aria", { renderer: entry.displayLabel }),
        heading: t("artifact_renderers.discuss.heading", { renderer: entry.displayLabel }),
        close: t("artifact_renderers.discuss.close"),
        capturing: t("artifact_renderers.discuss.capturing"),
        captureFailed: t("artifact_renderers.discuss.capture_failed"),
        screenshotAlt: t("artifact_renderers.discuss.screenshot_alt", { renderer: entry.displayLabel }),
        annotate: t("artifact_renderers.discuss.annotate"),
        promptLabel: t("artifact_renderers.discuss.prompt_label"),
        promptPlaceholder: t("artifact_renderers.discuss.prompt_placeholder"),
        metadataSummary: t("artifact_renderers.discuss.metadata_summary"),
        chatFailed: t("artifact_renderers.discuss.chat_failed"),
        cancel: t("artifact_renderers.discuss.cancel"),
        submit: t("artifact_renderers.discuss.submit"),
        starting: t("artifact_renderers.discuss.starting")
      }}
      previewRef={previewRef}
    />
  )
}

function ArtifactMetadataPanel({ artifact, entry }: { artifact: TypedArtifact; entry: ArtifactRendererEntry }) {
  const { t } = useT("syrus_dev")

  return (
    <DescriptionList.Root density="compact">
      <DescriptionList.Item label={t("artifact_renderers.meta_title")}>{artifact.title}</DescriptionList.Item>
      <DescriptionList.Item label={t("artifact_renderers.meta_type")}>
        <code>{artifact.type}</code>
      </DescriptionList.Item>
      <DescriptionList.Item label={t("artifact_renderers.meta_renderer_type")}>
        <code>{entry.rendererType}</code>
      </DescriptionList.Item>
      <DescriptionList.Item label={t("artifact_renderers.meta_owner")}>
        {entry.ownerType}
        {entry.pluginName ? ` · ${entry.pluginName}` : ""}
      </DescriptionList.Item>
      <DescriptionList.Item label={t("artifact_renderers.meta_created_at")}>{artifact.created_at}</DescriptionList.Item>
      {provenanceItems(artifact, t).map(([label, value]) => (
        <DescriptionList.Item key={label} label={label}>
          {value}
        </DescriptionList.Item>
      ))}
      <DescriptionList.Item label={t("artifact_renderers.meta_payload")}>{payloadSummary(artifact.payload, t)}</DescriptionList.Item>
    </DescriptionList.Root>
  )
}
