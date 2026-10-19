import type { ToolCardContext } from "@app/pluginToolCards"
import { CardShell, decimalCost, EmptyState, EntityReference, numberValue, Row, SectionLabel } from "@app/routes/chat/toolCardUi"
import { Pill, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"

type SpendPoint = { date: string; cost: number }
type TopRun = { jobId: number; title: string; cost: number }
type SpendingResult = { cost: number; inputTokens: number; outputTokens: number; byDay: SpendPoint[]; topRuns: TopRun[] }

const WINDOWS = new Set(["7d", "30d", "90d"])

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

export function spendingCost(value: unknown) {
  return decimalCost(value)?.replace(/(\.\d{2})00$/, "$1") ?? null
}

function stringValue(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null
}

function spendPoint(value: unknown): SpendPoint | null {
  if (!isPlainObject(value)) return null
  const date = stringValue(value.date)
  const cost = numberValue(value.cost_usd)
  return date && cost != null ? { date, cost } : null
}

function topRun(value: unknown): TopRun | null {
  if (!isPlainObject(value)) return null
  const jobId = numberValue(value.job_id)
  const title = stringValue(value.title)
  const cost = numberValue(value.cost_usd)
  return jobId != null && title && cost != null ? { jobId, title, cost } : null
}

export function spendingResult(context: ToolCardContext): SpendingResult | null {
  const value = context.parsedResult
  if (!isPlainObject(value) || !Array.isArray(value.by_day) || !Array.isArray(value.top_runs)) return null
  const cost = numberValue(value.total_cost_usd)
  const inputTokens = numberValue(value.total_input_tokens)
  const outputTokens = numberValue(value.total_output_tokens)
  const byDay = value.by_day.map(spendPoint)
  const topRuns = value.top_runs.map(topRun)
  if (cost == null || inputTokens == null || outputTokens == null || byDay.some((point) => !point) || topRuns.some((run) => !run)) return null
  return { cost, inputTokens, outputTokens, byDay: byDay as SpendPoint[], topRuns: topRuns as TopRun[] }
}

export function spendingWindow(context: ToolCardContext) {
  const window = stringValue(context.input?.window) ?? "30d"
  return WINDOWS.has(window) ? window : null
}

function DailySpend({ points }: { points: SpendPoint[] }) {
  const { t } = useT("spending")
  const maximum = Math.max(...points.map((point) => point.cost), 0)
  return (
    <div className="space-y-1">
      <SectionLabel>{t("tool_daily_spend")}</SectionLabel>
      <div className="flex h-16 items-end gap-px overflow-hidden" aria-label={t("tool_daily_spend")}>
        {points.map((point) => (
          <div
            aria-label={t("tool_day_cost", { date: point.date, cost: spendingCost(point.cost) })}
            className="min-w-0 flex-1 rounded-t bg-brand/70"
            key={point.date}
            style={{ height: maximum > 0 ? `${Math.max((point.cost / maximum) * 100, point.cost > 0 ? 6 : 1)}%` : "1px" }}
            title={`${point.date}: ${spendingCost(point.cost)}`}
          />
        ))}
      </div>
    </div>
  )
}

export function SpendingCard({ context }: { context: ToolCardContext }) {
  const { t } = useT("spending")
  const window = spendingWindow(context)
  if (!window || context.resultError) {
    return (
      <CardShell>
        <Text tone="danger">{t("tool_invalid_window")}</Text>
      </CardShell>
    )
  }

  const result = spendingResult(context)
  if (!result) return null
  const repositoryId = numberValue(context.input?.repository_id)
  const epicId = numberValue(context.input?.epic_id)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Pill tone="neutral">{window}</Pill>
        {repositoryId != null ? <EntityReference kind="repository" repositoryId={repositoryId} label={t("tool_repository", { id: repositoryId })} /> : null}
        {epicId != null ? <EntityReference kind="epic" id={epicId} wrap="nowrap" /> : null}
      </div>
      {result.cost === 0 ? (
        <EmptyState>{t("tool_no_spend")}</EmptyState>
      ) : (
        <>
          <dl className="grid grid-cols-1 gap-2 sm:grid-cols-3">
            <Row label={t("tool_total_cost")} value={spendingCost(result.cost) ?? "$0.00"} />
            <Row label={t("tool_input_tokens")} value={result.inputTokens.toLocaleString()} />
            <Row label={t("tool_output_tokens")} value={result.outputTokens.toLocaleString()} />
          </dl>
          <DailySpend points={result.byDay} />
          {result.topRuns.length > 0 ? (
            <div className="space-y-1">
              <SectionLabel>{t("tool_top_runs")}</SectionLabel>
              <div className="divide-y divide-border overflow-hidden rounded border border-border">
                {result.topRuns.map((run) => (
                  <div className="grid min-w-0 grid-cols-[auto_minmax(0,1fr)_auto] items-center gap-2 px-2 py-1.5" key={run.jobId}>
                    <EntityReference kind="job" id={run.jobId} wrap="nowrap" />
                    <Text className="truncate" title={run.title}>
                      {run.title}
                    </Text>
                    <Text className="whitespace-nowrap font-mono" variant="caption">
                      {spendingCost(run.cost)}
                    </Text>
                  </div>
                ))}
              </div>
            </div>
          ) : null}
        </>
      )}
    </CardShell>
  )
}
