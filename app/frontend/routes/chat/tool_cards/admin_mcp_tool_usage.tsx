import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, InternalLink, numberValue, SectionLabel, StatePill } from "../toolCardUi"
import { Table, TBody, Td, THead } from "../adminToolCard"

type UsageWindow = { start: string | null; end: string | null }
type Totals = { calls: number; errors: number }
type ToolRow = { key: string; toolName: string; serverName: string | null; calls: number; errors: number; errorRate: number }
type BreakdownRow = { key: string; label: string; calls: number; errors: number; errorRate: number }
type CardGapRow = {
  key: string
  toolName: string
  calls: number | null
  errors: number | null
  errorRate: number | null
  ownerType: string
  ownerName: string
  recommendationTarget: string
  cardStatus: string
}
type RecentCall = {
  key: string
  occurredAt: string | null
  toolName: string
  serverName: string | null
  surface: string | null
  provider: string | null
  sidecarMode: string | null
  status: string
  error: boolean
  errorSummary: string | null
  links: Array<{ key: string; label: string; href: string }>
}

type UsageCard = {
  unavailableMessage: string | null
  window: UsageWindow
  surface: string | null
  filters: { toolName: string | null; serverName: string | null }
  totals: Totals
  topTools: ToolRow[]
  errorRates: ToolRow[]
  surfaceBreakdown: BreakdownRow[]
  providerBreakdown: BreakdownRow[]
  serverBreakdown: BreakdownRow[]
  sidecarModeBreakdown: BreakdownRow[]
  unusedAdvertisedTools: string[]
  customCardGaps: {
    highVolumeWithoutCustomCard: CardGapRow[]
    highErrorWithWeakOrNoCustomCard: CardGapRow[]
    unusedAdvertisedTools: CardGapRow[]
  }
  recentCalls: RecentCall[]
}

function percent(value: number) {
  return `${(Math.round(value * 1000) / 10).toFixed(1)}%`
}

function parseToolRow(value: unknown, index: number): ToolRow | null {
  if (!isPlainObject(value)) return null
  const toolName = displayValue(value.tool_name)
  const calls = numberValue(value.calls)
  const errors = numberValue(value.errors)
  const errorRate = numberValue(value.error_rate)
  if (!toolName || calls == null || errors == null || errorRate == null) return null

  const serverName = displayValue(value.server_name)
  return { key: `${serverName ?? "-"}-${toolName}-${index}`, toolName, serverName, calls, errors, errorRate }
}

function parseBreakdownRow(value: unknown, labelKey: string, index: number): BreakdownRow | null {
  if (!isPlainObject(value)) return null
  const calls = numberValue(value.calls)
  const errors = numberValue(value.errors)
  const errorRate = numberValue(value.error_rate)
  if (calls == null || errors == null || errorRate == null) return null

  const label = displayValue(value[labelKey]) || "unknown"
  return { key: `${label}-${index}`, label, calls, errors, errorRate }
}

function parseCardGapRow(value: unknown, index: number): CardGapRow | null {
  if (!isPlainObject(value)) return null
  const toolName = displayValue(value.tool_name)
  const ownerType = displayValue(value.owner_type)
  const ownerName = displayValue(value.owner_name)
  const recommendationTarget = displayValue(value.recommendation_target)
  const cardStatus = displayValue(value.card_status)
  if (!toolName || !ownerType || !ownerName || !recommendationTarget || !cardStatus) return null

  return {
    key: `${toolName}-${cardStatus}-${index}`,
    toolName,
    calls: numberValue(value.calls),
    errors: numberValue(value.errors),
    errorRate: numberValue(value.error_rate),
    ownerType,
    ownerName,
    recommendationTarget,
    cardStatus
  }
}

function parseCardGapRows(value: unknown): CardGapRow[] {
  return Array.isArray(value) ? value.flatMap((row, index) => {
    const parsedRow = parseCardGapRow(row, index)
    return parsedRow ? [parsedRow] : []
  }) : []
}

function linkFor(row: Record<string, unknown>, key: "job" | "workflow" | "run" | "chat_session") {
  const href = displayValue(row[`${key === "chat_session" ? "chat" : key}_path`])
  if (!href) return null

  const id = displayValue(row[`${key}_id`])
  const label = key === "job" && id ? `JOB-${id}` : key === "workflow" && id ? `WF-${id}` : key === "run" && id ? `RUN-${id}` : "Chat"
  return { key, label, href }
}

function parseRecentCall(value: unknown, index: number): RecentCall | null {
  if (!isPlainObject(value)) return null
  const toolName = displayValue(value.tool_name)
  const status = displayValue(value.status)
  if (!toolName || !status) return null

  const links = (["job", "workflow", "run", "chat_session"] as const).flatMap((key) => {
    const link = linkFor(value, key)
    return link ? [link] : []
  })

  return {
    key: displayValue(value.id) || `${toolName}-${index}`,
    occurredAt: displayValue(value.occurred_at),
    toolName,
    serverName: displayValue(value.server_name),
    surface: displayValue(value.surface),
    provider: displayValue(value.provider),
    sidecarMode: displayValue(value.sidecar_mode),
    status,
    error: value.error === true,
    errorSummary: [displayValue(value.error_class), displayValue(value.error_message_summary)].filter(Boolean).join(": ") || null,
    links
  }
}

function parseFilters(value: unknown) {
  if (!isPlainObject(value)) return { toolName: null, serverName: null }
  return { toolName: displayValue(value.tool_name), serverName: displayValue(value.server_name) }
}

function parseCustomCardGaps(value: unknown) {
  const gaps = isPlainObject(value) ? value : {}
  return {
    highVolumeWithoutCustomCard: parseCardGapRows(gaps.high_volume_without_custom_card),
    highErrorWithWeakOrNoCustomCard: parseCardGapRows(gaps.high_error_with_weak_or_no_custom_card),
    unusedAdvertisedTools: parseCardGapRows(gaps.unused_advertised_tools)
  }
}

function parseUsage(context: ToolCardContext): UsageCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const window = isPlainObject(parsed.window) ? parsed.window : {}
  const totals = isPlainObject(parsed.totals) ? parsed.totals : null
  const calls = totals ? numberValue(totals.calls) : null
  const errors = totals ? numberValue(totals.errors) : null
  const unavailableMessage = displayValue(parsed.unavailable) || displayValue(parsed.error) || displayValue(parsed.message)

  if (calls == null || errors == null) {
    if (!unavailableMessage) return null
  }

  return {
    unavailableMessage: calls == null || errors == null ? unavailableMessage || "MCP usage data is unavailable." : null,
    window: { start: displayValue(window.start), end: displayValue(window.end) },
    surface: displayValue(parsed.surface),
    filters: parseFilters(parsed.filters),
    totals: { calls: calls ?? 0, errors: errors ?? 0 },
    topTools: Array.isArray(parsed.top_tools) ? parsed.top_tools.flatMap((row, index) => { const parsedRow = parseToolRow(row, index); return parsedRow ? [parsedRow] : [] }) : [],
    errorRates: Array.isArray(parsed.error_rates) ? parsed.error_rates.flatMap((row, index) => { const parsedRow = parseToolRow(row, index); return parsedRow && parsedRow.errors > 0 ? [parsedRow] : [] }) : [],
    surfaceBreakdown: Array.isArray(parsed.surface_breakdown) ? parsed.surface_breakdown.flatMap((row, index) => { const parsedRow = parseBreakdownRow(row, "surface", index); return parsedRow ? [parsedRow] : [] }) : [],
    providerBreakdown: Array.isArray(parsed.provider_breakdown) ? parsed.provider_breakdown.flatMap((row, index) => { const parsedRow = parseBreakdownRow(row, "provider", index); return parsedRow ? [parsedRow] : [] }) : [],
    serverBreakdown: Array.isArray(parsed.server_breakdown) ? parsed.server_breakdown.flatMap((row, index) => { const parsedRow = parseBreakdownRow(row, "server_name", index); return parsedRow ? [parsedRow] : [] }) : [],
    sidecarModeBreakdown: Array.isArray(parsed.sidecar_mode_breakdown) ? parsed.sidecar_mode_breakdown.flatMap((row, index) => { const parsedRow = parseBreakdownRow(row, "sidecar_mode", index); return parsedRow ? [parsedRow] : [] }) : [],
    unusedAdvertisedTools: Array.isArray(parsed.unused_advertised_tools) ? parsed.unused_advertised_tools.flatMap((tool) => { const name = displayValue(tool); return name ? [name] : [] }) : [],
    customCardGaps: parseCustomCardGaps(parsed.custom_card_gaps),
    recentCalls: Array.isArray(parsed.recent_calls) ? parsed.recent_calls.flatMap((row, index) => { const parsedRow = parseRecentCall(row, index); return parsedRow ? [parsedRow] : [] }) : []
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseUsage(context)
  if (!card) return null
  if (card.unavailableMessage) return card.unavailableMessage

  const rate = card.totals.calls > 0 ? card.totals.errors / card.totals.calls : 0
  const window = card.window.start && card.window.end ? `${card.window.start} to ${card.window.end}` : "selected window"
  return `${window}, ${card.surface || "all"} surface, ${card.totals.calls} calls, ${card.totals.errors} errors, ${percent(rate)} error rate`
}

function StatTile({ label, value, tone = "neutral" }: { label: string; value: string | number; tone?: "neutral" | "volume" | "error" }) {
  const toneClass = tone === "error"
    ? "border-red-200 bg-red-50 dark:border-red-900/60 dark:bg-red-950/30"
    : tone === "volume"
      ? "border-info/20 bg-info/5"
      : "border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950"
  return (
    <div className={`rounded border px-2 py-1 ${toneClass}`}>
      <div className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <div className="font-mono text-sm font-semibold text-gray-900 dark:text-gray-100">{value}</div>
    </div>
  )
}

function ToolRows({ heading, intent, rows }: { heading: string; intent: "volume" | "error"; rows: ToolRow[] }) {
  return (
    <div className={`rounded border ${intent === "error" ? "border-red-200 dark:border-red-900/60" : "border-info/20"}`}>
      <div className={`border-l-4 px-2 py-1 ${intent === "error" ? "border-red-500" : "border-info"}`}>
        <SectionLabel>{heading}</SectionLabel>
      </div>
      {rows.length === 0 ? (
        <EmptyState>{intent === "error" ? "No high-error tools in this window." : "No tool volume in this window."}</EmptyState>
      ) : (
        <Table>
          <THead columns={["Tool", "Calls", "Errors", "Rate"]} />
          <TBody>
            {rows.map((row) => (
              <tr key={row.key}>
                <Td maxWidth title={row.serverName ? `${row.serverName}.${row.toolName}` : row.toolName}>
                  <div className="font-medium text-gray-900 dark:text-gray-100">{row.toolName}</div>
                  <div className="text-2xs text-gray-500 dark:text-gray-400">{row.serverName || "-"}</div>
                </Td>
                <Td mono>{row.calls}</Td>
                <Td mono>{row.errors}</Td>
                <Td mono>{percent(row.errorRate)}</Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </div>
  )
}

function BreakdownRows({ label, rows }: { label: string; rows: BreakdownRow[] }) {
  if (rows.length === 0) return null
  return (
    <div>
      <SectionLabel>{label}</SectionLabel>
      <Table>
        <THead columns={[label, "Calls", "Errors", "Rate"]} />
        <TBody>
          {rows.map((row) => (
            <tr key={row.key}>
              <Td maxWidth title={row.label}>{row.label}</Td>
              <Td mono>{row.calls}</Td>
              <Td mono>{row.errors}</Td>
              <Td mono>{percent(row.errorRate)}</Td>
            </tr>
          ))}
        </TBody>
      </Table>
    </div>
  )
}

function CardGapRows({ heading, rows, showVolume = true }: { heading: string; rows: CardGapRow[]; showVolume?: boolean }) {
  return (
    <div className="rounded border border-amber-200 dark:border-amber-900/60">
      <div className="border-l-4 border-amber-500 px-2 py-1">
        <SectionLabel>{heading}</SectionLabel>
      </div>
      {rows.length === 0 ? (
        <EmptyState>No card coverage gaps in this bucket.</EmptyState>
      ) : (
        <Table>
          <THead columns={showVolume ? ["Tool", "Usage", "Card", "Target"] : ["Tool", "Card", "Target"]} />
          <TBody>
            {rows.map((row) => (
              <tr key={row.key}>
                <Td maxWidth title={row.toolName}>
                  <div className="font-medium text-gray-900 dark:text-gray-100">{row.toolName}</div>
                  <div className="text-2xs text-gray-500 dark:text-gray-400">{row.ownerType === "plugin" ? row.ownerName : "core"}</div>
                </Td>
                {showVolume ? (
                  <Td mono>
                    {row.calls == null ? "-" : `${row.calls} calls`}
                    {row.errors != null && row.errorRate != null ? <div className="text-2xs text-gray-500 dark:text-gray-400">{row.errors} errors, {percent(row.errorRate)}</div> : null}
                  </Td>
                ) : null}
                <Td><StatePill state={row.cardStatus} tone={row.cardStatus === "registered" ? "success" : "warning"} /></Td>
                <Td maxWidth title={row.recommendationTarget}>{row.recommendationTarget}</Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </div>
  )
}

function RecentCalls({ calls }: { calls: RecentCall[] }) {
  if (calls.length === 0) return <EmptyState>No recent calls found.</EmptyState>

  return (
    <Table>
      <THead columns={["When", "Call", "Status", "Links"]} />
      <TBody>
        {calls.map((call) => (
          <tr key={call.key}>
            <Td mono>{call.occurredAt || "-"}</Td>
            <Td maxWidth title={[call.serverName, call.toolName].filter(Boolean).join(".")}>
              <div className="font-medium text-gray-900 dark:text-gray-100">{call.toolName}</div>
              <div className="text-2xs text-gray-500 dark:text-gray-400">{[call.serverName || "-", call.surface, call.provider, call.sidecarMode].filter(Boolean).join(" / ")}</div>
            </Td>
            <Td maxWidth title={call.errorSummary || undefined}>
              <StatePill state={call.status} tone={call.error ? "failure" : "success"} />
              {call.errorSummary ? <div className="mt-1 truncate text-2xs text-gray-500 dark:text-gray-400">{call.errorSummary}</div> : null}
            </Td>
            <Td>
              {call.links.length === 0 ? "—" : (
                <div className="flex flex-wrap gap-1">
                  {call.links.map((link) => <InternalLink href={link.href} key={link.key}>{link.label}</InternalLink>)}
                </div>
              )}
            </Td>
          </tr>
        ))}
      </TBody>
    </Table>
  )
}

function renderExpanded(context: ToolCardContext) {
  const card = parseUsage(context)
  if (!card) return null

  if (card.unavailableMessage) return <EmptyState>{card.unavailableMessage}</EmptyState>

  const rate = card.totals.calls > 0 ? card.totals.errors / card.totals.calls : 0
  const filters = [card.filters.toolName ? `tool: ${card.filters.toolName}` : null, card.filters.serverName ? `server: ${card.filters.serverName}` : null].filter(Boolean)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Badge>{card.surface || "all"} surface</Badge>
        {card.window.start && card.window.end ? <Badge>{card.window.start} to {card.window.end}</Badge> : null}
        {filters.map((filter) => <Badge key={filter}>{filter}</Badge>)}
      </div>
      <div className="grid grid-cols-3 gap-2">
        <StatTile label="Calls" value={card.totals.calls} tone="volume" />
        <StatTile label="Errors" value={card.totals.errors} tone={card.totals.errors > 0 ? "error" : "neutral"} />
        <StatTile label="Error rate" value={percent(rate)} tone={card.totals.errors > 0 ? "error" : "neutral"} />
      </div>
      {card.totals.calls === 0 ? <EmptyState>No MCP tool calls found for this window.</EmptyState> : null}
      <div className="grid gap-2 lg:grid-cols-2">
        <ToolRows heading="Volume priorities" intent="volume" rows={card.topTools} />
        <ToolRows heading="Error priorities" intent="error" rows={card.errorRates} />
      </div>
      <div className="grid gap-2 lg:grid-cols-3">
        <CardGapRows heading="Missing high-volume cards" rows={card.customCardGaps.highVolumeWithoutCustomCard} />
        <CardGapRows heading="Weak or missing error cards" rows={card.customCardGaps.highErrorWithWeakOrNoCustomCard} />
        <CardGapRows heading="Unused advertised tools" rows={card.customCardGaps.unusedAdvertisedTools} showVolume={false} />
      </div>
      <div className="grid gap-2 lg:grid-cols-2">
        <BreakdownRows label="Surface" rows={card.surfaceBreakdown} />
        <BreakdownRows label="Provider" rows={card.providerBreakdown} />
        <BreakdownRows label="Server" rows={card.serverBreakdown} />
        <BreakdownRows label="Sidecar mode" rows={card.sidecarModeBreakdown} />
      </div>
      {card.unusedAdvertisedTools.length > 0 ? (
        <div>
          <SectionLabel>Unused advertised tools</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {card.unusedAdvertisedTools.map((tool) => <Badge key={tool}>{tool}</Badge>)}
          </div>
        </div>
      ) : null}
      <div>
        <SectionLabel>Recent calls</SectionLabel>
        <RecentCalls calls={card.recentCalls} />
      </div>
    </CardShell>
  )
}

const adminMcpToolUsageToolCard: ToolCardRenderer = {
  toolName: "admin_mcp_tool_usage",
  collapsedSummary,
  renderExpanded
}

export default adminMcpToolUsageToolCard
