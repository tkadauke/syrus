import { useEffect, useMemo, useRef, useState } from "react"
import { useLocation } from "react-router-dom"
import type { ChatToolGroupCall, ChatToolGroupItem } from "@app/api/chats"
import { FilterBar, type FilterLinkBuilder, type FilterSchemaField, type FilterTree } from "@app/components/FilterBar"
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

type RendererType = "custom_card" | "generic_fallback"
type CoverageStatus = "has_examples" | "no_examples"

const FILTER_FIELDS = ["tool_name", "owner_type", "owner_name", "source_type", "renderer_type", "coverage_status"] as const
type CatalogFilterField = (typeof FILTER_FIELDS)[number]

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

function rendererTypeFor(entry: ToolPresentationEntry): RendererType {
  return entry.renderer ? "custom_card" : "generic_fallback"
}

function coverageStatusFor(entry: ToolPresentationEntry): CoverageStatus {
  return entry.examples.length > 0 ? "has_examples" : "no_examples"
}

function ownerTone(ownerType: ToolOwnerType): SemanticTone {
  if (ownerType === "core") return "neutral"
  if (ownerType === "plugin") return "info"
  return "warning"
}

export function anchorId(toolName: string) {
  return `tool-${toolName.replace(/[^a-zA-Z0-9_-]/g, "_")}`
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

function filtersFromSearch(search: string): Partial<Record<CatalogFilterField, string>> {
  const params = new URLSearchParams(search)
  const filters: Partial<Record<CatalogFilterField, string>> = {}
  for (const field of FILTER_FIELDS) {
    const value = params.get(field)?.trim()
    if (value) filters[field] = value
  }
  return filters
}

function filterTreeFromSearch(search: string): FilterTree {
  const filters = filtersFromSearch(search)
  const and = FILTER_FIELDS.flatMap((field) => {
    const value = filters[field]
    return value ? [{ field, op: field === "tool_name" ? "contains" : "is", value }] : []
  })
  return { and }
}

// FilterBar's chip UI only speaks its own base64 `q=<tree>` wire format; this
// project's filter state is flat query params instead (so a shared link is
// readable and the deep-link `tool`/`example` params stay independent of the
// filter tree encoding). Decode `q` back into flat params here, the same
// split ChatSearch.tsx uses for its own client-evaluated filter.
const catalogFilterLink: FilterLinkBuilder = (path, search, updates) => {
  const params = new URLSearchParams(search)
  const encodedFilter = updates.q

  for (const [key, value] of Object.entries(updates)) {
    if (key === "q") continue
    if (value == null || String(value).length === 0) params.delete(key)
    else params.set(key, String(value))
  }

  if (typeof encodedFilter === "string" && encodedFilter.length > 0) {
    for (const field of FILTER_FIELDS) params.delete(field)
    for (const chip of decodeFilterChips(encodedFilter)) {
      if ((FILTER_FIELDS as readonly string[]).includes(chip.field) && chip.value) params.set(chip.field, chip.value)
    }
  } else if (encodedFilter == null) {
    for (const field of FILTER_FIELDS) params.delete(field)
  }

  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function decodeFilterChips(encoded: string): Array<{ field: string; value: string }> {
  try {
    const standard = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const parsed = JSON.parse(atob(standard)) as { and?: unknown[] }
    return (parsed.and || []).flatMap((node) => {
      if (!node || typeof node !== "object" || !("field" in node) || !("value" in node)) return []
      const field = String((node as { field: unknown }).field)
      const value = (node as { value: unknown }).value
      return typeof value === "string" && value ? [{ field, value }] : []
    })
  } catch {
    return []
  }
}

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

  const filters = useMemo(() => filtersFromSearch(search), [search])
  const filterTree = useMemo(() => filterTreeFromSearch(search), [search])

  const filteredEntries = useMemo(
    () => allEntries.filter((entry) => matchesFilters(entry, filters)).sort((left, right) => left.toolName.localeCompare(right.toolName)),
    [allEntries, filters]
  )

  const params = new URLSearchParams(search)
  const deepLinkTool = params.get("tool")
  const deepLinkExample = params.get("example")
  const scrolledToRef = useRef<string | null>(null)

  useEffect(() => {
    if (!deepLinkTool || scrolledToRef.current === deepLinkTool) return
    const element = document.getElementById(anchorId(deepLinkTool))
    if (!element) return

    element.scrollIntoView({ block: "start" })
    scrolledToRef.current = deepLinkTool
  }, [deepLinkTool, filteredEntries])

  return (
    <Page.Root size="wide">
      <Page.Header>
        <Page.HeadingGroup>
          <Page.Title>{t("tool_cards.heading")}</Page.Title>
          <Page.Description>{t("tool_cards.description")}</Page.Description>
        </Page.HeadingGroup>
      </Page.Header>

      <FilterBar buildLink={catalogFilterLink} filter={filterTree} filterSchema={filterSchema} pathname={location.pathname} search={search} />

      <Text muted variant="caption">{t("tool_cards.showing", { count: filteredEntries.length, total: allEntries.length })}</Text>

      {filteredEntries.length === 0 ? (
        <PanelMessage>{t("tool_cards.no_match")}</PanelMessage>
      ) : (
        <div className="space-y-4">
          {filteredEntries.map((entry) => (
            <ToolCatalogEntry
              entry={entry}
              initialExampleId={entry.toolName === deepLinkTool ? deepLinkExample : null}
              key={entry.toolName}
            />
          ))}
        </div>
      )}
    </Page.Root>
  )
}

export default AdminToolCards

function ToolCatalogEntry({ entry, initialExampleId }: { entry: ToolPresentationEntry; initialExampleId?: string | null }) {
  const { t } = useT("syrus_dev")
  const { copied, copy } = useCopyToClipboard()
  const hasInitialMatch = Boolean(initialExampleId && entry.examples.some((example) => example.id === initialExampleId))
  const [selectedId, setSelectedId] = useState<string | null>(hasInitialMatch ? (initialExampleId as string) : entry.examples[0]?.id ?? null)
  const id = anchorId(entry.toolName)
  const headingId = `${id}-heading`

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
            {entry.examples.length > 1 ? (
              <div aria-label={t("tool_cards.example_selector_aria", { tool: entry.displayLabel })} className="flex flex-wrap gap-1.5" role="tablist">
                {entry.examples.map((example) => (
                  <button
                    aria-selected={example.id === selectedExample?.id}
                    className={
                      example.id === selectedExample?.id
                        ? "rounded-[var(--radius-control)] border border-brand bg-brand px-2 py-1 text-xs font-medium text-on-brand"
                        : "rounded-[var(--radius-control)] border border-border bg-surface px-2 py-1 text-xs font-medium text-text-secondary hover:bg-surface-raised"
                    }
                    key={example.id}
                    onClick={() => setSelectedId(example.id)}
                    role="tab"
                    type="button"
                  >
                    {example.label}
                  </button>
                ))}
              </div>
            ) : null}

            {selectedExample?.description ? <Text tone="muted" variant="caption">{selectedExample.description}</Text> : null}

            <div className="flex items-center justify-end">
              <button
                className="text-xs text-brand underline hover:no-underline"
                onClick={() => selectedExample && copy(deepLinkFor(selectedExample.id))}
                type="button"
              >
                {copied ? t("tool_cards.link_copied") : t("tool_cards.copy_link")}
              </button>
            </div>

            {group ? <ToolGroup item={group} /> : null}
          </>
        )}
      </Section.Body>
    </Section.Root>
  )
}
