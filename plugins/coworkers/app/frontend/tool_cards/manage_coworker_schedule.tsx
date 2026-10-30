import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, EmptyState, Row, StatePill } from "@app/routes/chat/toolCardUi"
import i18n from "@app/i18n"

function object(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value) ? (value as Record<string, unknown>) : null
}

const card: ToolCardRenderer = {
  toolName: "manage_coworker_schedule",
  collapsedSummary(context) {
    const result = object(context.parsedResult)
    const schedules = Array.isArray(result?.schedules) ? result.schedules : []
    return result ? `${schedules.length} schedule${schedules.length === 1 ? "" : "s"}` : null
  },
  renderExpanded(context) {
    const result = object(context.parsedResult)
    if (!result) return <EmptyState>{context.resultBody || "Schedule action failed."}</EmptyState>
    const schedules = Array.isArray(result.schedules) ? result.schedules : []
    return (
      <CardShell>
        {result.fired === true ? <Row label="Run" value={<StatePill state="Started" tone="success" />} /> : null}
        {schedules.length ? (
          schedules.map((value, index) => {
            const schedule = object(value)
            return (
              <Row
                key={String(schedule?.id || index)}
                label={String(schedule?.name || "Schedule")}
                value={`${String(schedule?.schedule || "—")} · ${String(schedule?.state || "")}`}
              />
            )
          })
        ) : (
          <EmptyState>{i18n.t("coworkers:tool_card.no_schedules")}</EmptyState>
        )}
      </CardShell>
    )
  }
}

export default card
