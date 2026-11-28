import { isPlainObject, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, Row } from "@app/routes/chat/toolCardUi"
import i18n from "@app/i18n"

export function environmentToolCard(toolName: string): ToolCardRenderer {
  return {
    toolName,
    collapsedSummary(context) {
      if (!isPlainObject(context.parsedResult)) return null
      const environment = context.parsedResult.environment
      return isPlainObject(environment) ? displayValue(environment.state) : null
    },
    renderExpanded(context) {
      if (!isPlainObject(context.parsedResult)) return null
      const environment = context.parsedResult.environment
      if (!isPlainObject(environment)) return null
      const compatibility = environment.compatibility
      const build = environment.build_status
      return (
        <CardShell>
          <Row label={i18n.t("coworkers:tool_card.environment_state")} value={displayValue(environment.state)} />
          {isPlainObject(build) ? <Row label={i18n.t("coworkers:tool_card.environment_build")} value={displayValue(build.state)} /> : null}
          {isPlainObject(compatibility) ? <Row label={i18n.t("coworkers:tool_card.environment_compatibility")} value={displayValue(compatibility.status)} /> : null}
          <Row label={i18n.t("coworkers:tool_card.environment_active_image")} value={displayValue(environment.active_digest)} />
          <Row label={i18n.t("coworkers:tool_card.environment_failure")} value={displayValue(environment.error_code)} />
        </CardShell>
      )
    }
  }
}
