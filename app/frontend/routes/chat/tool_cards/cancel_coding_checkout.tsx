import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { LocalModeJobOutcomeToolCard, localModeJobOutcomeModel, localModeJobOutcomeSummary } from "../localModeJobOutcomeCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EntityReference, StatePill } from "../toolCardUi"

function collapsedSummary(context: ToolCardContext) {
  const model = localModeJobOutcomeModel(context)
  if (model.error) return "Coding Mode cancellation failed"
  return model.result ? localModeJobOutcomeSummary(model.result) : "Coding Mode checkout canceled"
}

const cancelCodingCheckoutToolCard: ToolCardRenderer = {
  toolName: "cancel_coding_checkout",
  collapsedSummary,
  renderExpanded: (context) => {
    const model = localModeJobOutcomeModel(context)
    if (model.error || model.result) return <LocalModeJobOutcomeToolCard context={context} />
    const value = isPlainObject(context.parsedResult) ? context.parsedResult : {}
    const repositorySlug = displayValue(value.repository_slug)
    const message = displayValue(value.message)
    if (!repositorySlug && !message) return <LocalModeJobOutcomeToolCard context={context} />
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="canceled" />
          {repositorySlug ? <EntityReference kind="repository" repositorySlug={repositorySlug} slug={repositorySlug} /> : null}
        </div>
        {message ? <MarkdownPreview text={message} title="Outcome" /> : null}
      </CardShell>
    )
  }
}

export default cancelCodingCheckoutToolCard
