import { useMemo, useRef, useState } from "react"
import { useLocation } from "react-router-dom"
import type { ChatToolGroupCall, ChatToolGroupItem } from "@app/api/chats"
import { FilterBar, type FilterSchemaField } from "@app/components/FilterBar"
import { Badge, Page, PanelMessage, Section, Text, type SemanticTone } from "@app/components/ui"
import { useCopyToClipboard } from "@app/hooks/useCopyToClipboard"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { useT } from "@app/hooks/useT"
import { toolCardContextForExample } from "@app/pluginToolCards"
import { ToolGroup } from "@app/routes/chat/MessageCards"
import { toolResultPresentation } from "@app/routes/chat/toolRendering"
import {
  allToolPresentationEntries,
  type ToolOwnerType,
  type ToolPresentationEntry,
  type ToolPresentationExample
} from "@app/toolPresentationRegistry"
import { ToolCardDiscussButton } from "../components/ToolCardDiscussDialog"
import { CatalogExampleSelector } from "../catalog/CatalogExampleSelector"
import { buildCatalogFilterLink, catalogFilterTreeFromSearch, catalogFiltersFromSearch } from "../catalog/catalogFilterLink"
import { catalogAnchorId, useCatalogDeepLinkScroll } from "../catalog/catalogDeepLink"
import { CatalogViewportFrame, CatalogViewportSwitcher, viewportPresetFromSearch, type ViewportPresetId } from "../catalog/catalogViewport"
import { rendererTypeFor } from "../toolCardCatalogTypes"

// The Tool Card Catalog: every registered tool presentation (core/plugin MCP
// cards, provider built-ins, Local Mode tools, and chat-surface components --
// see toolPresentationRegistry.ts), reviewable from its own example fixtures
// without digging through a real transcript. Each entry renders through the
// exact same <ToolGroup> component real chat transcripts use, so collapsed
// row, expanded body, raw details, redaction, and generic-fallback behavior
// are never re-implemented here -- only composed from the registry + the
// real rendering path.
//
// This page reads a purely client-side, compiled registry -- there is no
// backend endpoint or persisted filter state, so filtering happens in this
// file against the in-memory entry list rather than through Filters::Subject
// (which exists for ActiveRecord-backed collections). FilterBar itself is
// still the shared chip-bar UI; only the "apply the filter" half is local,
// mirroring the pattern ChatSearch.tsx already uses for its own
// entirely-client-evaluated flat filters.

type CoverageStatus = "has_examples" | "no_examples"

const FILTER_FIELDS = ["tool_name", "owner_type", "owner_name", "source_type", "renderer_type", "coverage_status"] as const
type CatalogFilterField = (typeof FILTER_FIELDS)[number]
const TEXT_FILTER_FIELDS: readonly CatalogFilterField[] = ["tool_name"]

const OWNER_TYPE_OPTIONS = [
  { value: "core", label: "Core" },
  { value: "plugin", label: "Plugin" },
  { value: "provider", label: "Provider" }
]

const SOURCE_TYPE_OPTIONS = [
  { value: "mcp_tool", label: "MCP tool" },
  { value: "provider_builtin", label: "Provider built-in" },
  { value: "local_mode_tool", label: "Local Mode tool" },
  { value: "chat_surface_component", label: "Chat surface component" },
  { value: "fallback_only", label: "Fallback only" }
]

const RENDERER_TYPE_OPTIONS = [
  { value: "custom_card", label: "Custom card" },
  { value: "generic_fallback", label: "Generic fallback" }
]

const COVERAGE_STATUS_OPTIONS = [
  { value: "has_examples", label: "Has examples" },
  { value: "no_examples", label: "No examples" }
]

function coverageStatusFor(entry: ToolPresentationEntry): CoverageStatus {
  return entry.examples.length > 0 ? "has_examples" : "no_examples"
}

function ownerTone(ownerType: ToolOwnerType): SemanticTone {
  if (ownerType === "core") return "neutral"
  if (ownerType === "plugin") return "info"
  return "warning"
}

export function anchorId(toolName: string) {
  return catalogAnchorId("tool", toolName)
}

function matchesFilters(entry: ToolPresentationEntry, filters: Partial<Record<CatalogFilterField, string>>) {
  if (filters.tool_name) {
    const needle = filters.tool_name.toLowerCase()
    const haystack = [entry.toolName, entry.displayLabel, ...entry.aliases].join(" ").toLowerCase()
    if (!haystack.includes(needle)) return false
  }
  if (filters.owner_type && entry.ownerType !== filters.owner_type) return false
  if (filters.owner_name && entry.ownerName !== filters.owner_name) return false
  if (filters.source_type && entry.sourceType !== filters.source_type) return false
  if (filters.renderer_type && rendererTypeFor(entry) !== filters.renderer_type) return false
  if (filters.coverage_status && coverageStatusFor(entry) !== filters.coverage_status) return false
  return true
}

const catalogFilterLink = buildCatalogFilterLink(FILTER_FIELDS)

// Builds a real ChatToolGroupCall from a registered example fixture, using
// the exact same helpers streamBuilders.ts uses to turn a live tool_use/
// tool_result pair into one -- toolCardContextForExample resolves the
// example's resultBody/parsedResult exactly like a live transcript would,
// and toolResultPresentation derives result_kind/result_summary (including
// running a registered card's own collapsedSummary). Nothing about
// presentation is re-derived independently here.
function callForExample(entry: ToolPresentationEntry, example: ToolPresentationExample, messageId: number): ChatToolGroupCall {
  const context = toolCardContextForExample(entry.toolName, example)
  const input = context.input ?? {}
  const resultPresentation = toolResultPresentation(entry.toolName, context.resultBody, context.resultError, context.resultBody, input, context.parsedResult)

  return {
    message_id: messageId,
    tool_name: entry.toolName,
    raw_name: entry.toolName,
    detail: entry.argumentSummary(input),
    display_label: entry.displayLabel,
    progress_label: entry.progressLabel,
    raw_payload: input,
    result_body: context.resultBody,
    result_settled: true,
    result_json: context.parsedResult,
    result_error: context.resultError,
    result_kind: resultPresentation.kind,
    result_summary: resultPresentation.summary,
    summary_metadata: resultPresentation.metadata
  }
}

export function AdminToolCards() {
  const { t } = useT("syrus_dev")
  usePageTitle(t("tool_cards.heading"))
  const location = useLocation()
  const search = location.search

  const allEntries = useMemo(() => allToolPresentationEntries(), [])

  const ownerNameOptions = useMemo(() => {
    const names = Array.from(new Set(allEntries.map((entry) => entry.ownerName))).sort()
    return names.map((name) => ({ value: name, label: name }))
  }, [allEntries])

  const filterSchema: FilterSchemaField[] = useMemo(() => [
    { field: "tool_name", label: t("tool_cards.filter_tool_name"), bucket: "text", operators: ["contains"], values: [] },
    { field: "owner_type", label: t("tool_cards.filter_owner_type"), bucket: "select", operators: ["is"], values: OWNER_TYPE_OPTIONS },
    { field: "owner_name", label: t("tool_cards.filter_owner_name"), bucket: "select", operators: ["is"], values: ownerNameOptions },
    { field: "source_type", label: t("tool_cards.filter_source_type"), bucket: "select", operators: ["is"], values: SOURCE_TYPE_OPTIONS },
    { field: "renderer_type", label: t("tool_cards.filter_renderer_type"), bucket: "select", operators: ["is"], values: RENDERER_TYPE_OPTIONS },
    { field: "coverage_status", label: t("tool_cards.filter_coverage_status"), bucket: "select", operators: ["is"], values: COVERAGE_STATUS_OPTIONS }
  ], [t, ownerNameOptions])

  const filters = useMemo(() => catalogFiltersFromSearch(FILTER_FIELDS, search), [search])
  const filterTree = useMemo(() => catalogFilterTreeFromSearch(FILTER_FIELDS, TEXT_FILTER_FIELDS, search), [search])
  const selectedViewport = useMemo(() => viewportPresetFromSearch(search), [search])

  const filteredEntries = useMemo(
    () => allEntries.filter((entry) => matchesFilters(entry, filters)).sort((left, right) => left.toolName.localeCompare(right.toolName)),
    [allEntries, filters]
  )

  const params = new URLSearchParams(search)
  const deepLinkTool = params.get("tool")
  const deepLinkExample = params.get("example")

  useCatalogDeepLinkScroll(deepLinkTool ? anchorId(deepLinkTool) : null, filteredEntries)

  return (
    <Page.Root gutter="responsive" size="wide">
      <Page.Header>
        <Page.HeadingGroup>
          <Page.Title>{t("tool_cards.heading")}</Page.Title>
          <Page.Description>{t("tool_cards.description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      <Page.Nav className="space-y-4">
        <FilterBar buildLink={catalogFilterLink} filter={filterTree} filterSchema={filterSchema} pathname={location.pathname} search={search} />

        <div className="flex flex-wrap items-center justify-between gap-2">
          <Text muted variant="caption">{t("tool_cards.showing", { count: filteredEntries.length, total: allEntries.length })}</Text>
          <CatalogViewportSwitcher
            ariaLabel={t("tool_cards.viewport_switcher_aria")}
            labelFor={(preset) => t(`tool_cards.viewport_${preset.id}`, { width: preset.width })}
            pathname={location.pathname}
            search={search}
            selected={selectedViewport.id}
          />
        </div>
      </Page.Nav>

      {filteredEntries.length === 0 ? (
        <PanelMessage>{t("tool_cards.no_match")}</PanelMessage>
      ) : (
        <div className="space-y-4">
          {filteredEntries.map((entry) => (
            <ToolCatalogEntry
              entry={entry}
              initialExampleId={entry.toolName === deepLinkTool ? deepLinkExample : null}
              key={entry.toolName}
              previewWidth={selectedViewport.width}
              viewportPresetId={selectedViewport.id}
            />
          ))}
        </div>
      )}
    </Page.Root>
  )
}

export default AdminToolCards

function ToolCatalogEntry({
  entry,
  initialExampleId,
  previewWidth,
  viewportPresetId
}: {
  entry: ToolPresentationEntry
  initialExampleId?: string | null
  previewWidth: number
  viewportPresetId: ViewportPresetId
}) {
  const { t } = useT("syrus_dev")
  const { copied, copy } = useCopyToClipboard()
  const hasInitialMatch = Boolean(initialExampleId && entry.examples.some((example) => example.id === initialExampleId))
  const [selectedId, setSelectedId] = useState<string | null>(hasInitialMatch ? (initialExampleId as string) : entry.examples[0]?.id ?? null)
  const id = anchorId(entry.toolName)
  const headingId = `${id}-heading`
  const previewFrameRef = useRef<HTMLDivElement | null>(null)

  const selectedExample = entry.examples.find((example) => example.id === selectedId) ?? entry.examples[0] ?? null
  const group: ChatToolGroupItem | null = selectedExample
    ? { type: "tool_group", tool: entry.displayLabel, summary_label: entry.displayLabel, calls: [callForExample(entry, selectedExample, 0)] }
    : null

  function deepLinkFor(exampleId: string) {
    const url = new URL(window.location.href)
    url.searchParams.set("tool", entry.toolName)
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
            <code>{entry.toolName}</code>
            {entry.aliases.length > 0 ? <span> · {t("tool_cards.aliases", { aliases: entry.aliases.join(", ") })}</span> : null}
          </Section.Description>
        </div>
        <Section.Actions>
          <Badge tone={ownerTone(entry.ownerType)}>{entry.ownerType} · {entry.ownerName}</Badge>
          <Badge tone="neutral">{entry.sourceType}</Badge>
          <Badge tone={entry.renderer ? "success" : "warning"}>
            {entry.renderer ? t("tool_cards.renderer_custom_card") : t("tool_cards.renderer_generic_fallback")}
          </Badge>
          <Badge tone={entry.readOnly ? "info" : "warning"}>
            {entry.readOnly ? t("tool_cards.read_only") : t("tool_cards.side_effecting")}
          </Badge>
        </Section.Actions>
      </Section.Header>
      <Section.Body className="space-y-3">
        {entry.examples.length === 0 ? (
          <PanelMessage>{t("tool_cards.no_examples")}</PanelMessage>
        ) : (
          <>
            <CatalogExampleSelector
              ariaLabel={t("tool_cards.example_selector_aria", { tool: entry.displayLabel })}
              examples={entry.examples}
              onSelect={setSelectedId}
              selectedId={selectedExample?.id ?? null}
            />

            {selectedExample?.description ? <Text tone="muted" variant="caption">{selectedExample.description}</Text> : null}

            <div className="flex items-center justify-between gap-2">
              {selectedExample ? (
                <ToolCardDiscussButton
                  deepLink={deepLinkFor(selectedExample.id)}
                  entry={entry}
                  example={selectedExample}
                  previewRef={previewFrameRef}
                  viewportPresetId={viewportPresetId}
                />
              ) : <span />}
              <button
                className="text-xs text-brand underline hover:no-underline"
                onClick={() => selectedExample && copy(deepLinkFor(selectedExample.id))}
                type="button"
              >
                {copied ? t("tool_cards.link_copied") : t("tool_cards.copy_link")}
              </button>
            </div>

            {group ? (
              <CatalogViewportFrame
                ariaLabel={t("tool_cards.viewport_frame_aria", { width: previewWidth })}
                ref={previewFrameRef}
                width={previewWidth}
              >
                <ToolGroup item={group} />
              </CatalogViewportFrame>
            ) : null}
          </>
        )}
      </Section.Body>
    </Section.Root>
  )
}
