import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "@app/i18n"
import { displayValue, EmptyState, EntityReference } from "../toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

type RenameChatResult = { sessionId: string; title: string; previousTitle: string | null; requestedName: string | null }

function parseRenameChat(context: ToolCardContext) {
  if (!context.resultError && context.parsedResult == null && !context.resultBody) return { kind: "pending" } as const

  return successOrError<RenameChatResult>(context, i18n.t("chat:tool_card_chat_rename_failed_period"), (parsed) => {
    const sessionId = displayValue(parsed.session_id)
    const title = displayValue(parsed.title)
    if (!sessionId || !title) return null
    return {
      sessionId,
      title,
      previousTitle: displayValue(parsed.previous_title),
      requestedName: displayValue(context.input?.name)
    }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseRenameChat(context)
  if (parsed.kind === "pending") return i18n.t("chat:tool_card_chat_renaming")
  if (parsed.kind === "error") return i18n.t("chat:tool_card_chat_rename_failed")
  if (parsed.kind === "malformed") return i18n.t("chat:tool_card_chat_rename_unexpected")
  if (parsed.data.previousTitle) return i18n.t("chat:tool_card_chat_renamed_from", { oldTitle: parsed.data.previousTitle, title: parsed.data.title })
  return i18n.t("chat:tool_card_chat_renamed_to", { title: parsed.data.title })
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseRenameChat(context)
  if (parsed.kind === "pending") {
    return (
      <StatusCard title={i18n.t("chat:tool_card_chat_rename")} status="pending">
        <TitleField label={i18n.t("chat:tool_card_requested_title")} value={displayValue(context.input?.name)} />
      </StatusCard>
    )
  }
  if (parsed.kind === "error") return <ErrorCard title={i18n.t("chat:tool_card_chat_rename")} message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title={i18n.t("chat:tool_card_chat_rename")} />

  const requestedDiffers = parsed.data.requestedName && parsed.data.requestedName !== parsed.data.title

  return (
    <StatusCard title={i18n.t("chat:tool_card_chat_rename")} status="renamed">
      <dl className="grid gap-1 sm:grid-cols-2">
        <div className="min-w-0">
          <dt className="text-xs font-medium text-text-subtle">{i18n.t("chat:tool_card_chat")}</dt>
          <dd>
            <EntityReference id={parsed.data.sessionId} kind="chat" />
          </dd>
        </div>
        {parsed.data.previousTitle ? <TitleField label={i18n.t("chat:tool_card_old_title")} value={parsed.data.previousTitle} /> : null}
        {requestedDiffers ? <TitleField label={i18n.t("chat:tool_card_requested_title")} value={parsed.data.requestedName} /> : null}
        <TitleField label={i18n.t("chat:tool_card_stored_title")} value={parsed.data.title} />
      </dl>
    </StatusCard>
  )
}

function TitleField({ label, value }: { label: string; value: string | null }) {
  return (
    <div className="min-w-0">
      <dt className="text-xs font-medium text-text-subtle">{label}</dt>
      <dd className="whitespace-pre-wrap break-words font-mono text-xs text-text-primary">{value ?? <EmptyState>{i18n.t("chat:tool_card_not_provided")}</EmptyState>}</dd>
    </div>
  )
}

const renameChatToolCard: ToolCardRenderer = {
  toolName: "rename_chat",
  renderWhilePending: true,
  collapsedSummary,
  renderExpanded
}

export default renameChatToolCard

export const examples: ToolCardExample[] = [
  {
    id: "renamed_with_shortened_title",
    label: i18n.t("chat:tool_card_chat_rename_example_shortened"),
    input: { name: `${"Long requested title ".repeat(7)}ending` },
    parsedResult: {
      session_id: 42,
      previous_title: "Old title",
      title: `${"Long requested title ".repeat(5)}stored ending`
    }
  },
  {
    id: "rename_pending",
    label: i18n.t("chat:tool_card_chat_rename_example_pending"),
    input: { name: "Release planning" },
    parsedResult: null
  },
  {
    id: "name_required",
    label: i18n.t("chat:tool_card_chat_rename_example_required"),
    input: { name: "" },
    resultError: true,
    resultBody: "name is required"
  },
  {
    id: "name_too_long",
    label: i18n.t("chat:tool_card_chat_rename_example_long"),
    input: { name: "x".repeat(121) },
    resultError: true,
    resultBody: "name must be 120 characters or fewer"
  }
]
