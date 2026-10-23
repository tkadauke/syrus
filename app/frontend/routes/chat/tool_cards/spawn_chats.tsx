import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { MarkdownPreview } from "../toolCardMarkdown"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel } from "../toolCardUi"

const PREVIEW_CHARS = 720
const failureConfig: ToolFailureConfig = {
  title: "Spawn chats",
  attempted: (context) => `${Array.isArray(context.input?.chats) ? context.input.chats.length : 0} chats`,
  retrySafety: "safe",
  recovery: "Correct the chat prompts, providers, or repositories, then retry."
}

type ChatInput = { prompt: string; provider: string | null; title: string | null; repository: string | null }

function chatsFrom(context: ToolCardContext): ChatInput[] {
  if (!Array.isArray(context.input?.chats)) return []
  return context.input.chats.flatMap((value) => {
    if (!isPlainObject(value)) return []
    return [
      {
        prompt: typeof value.prompt === "string" ? value.prompt : "",
        provider: displayValue(value.provider),
        title: displayValue(value.title),
        repository: displayValue(value.repository)
      }
    ]
  })
}

function errorContext(context: ToolCardContext): ToolCardContext | null {
  const directError = isPlainObject(context.parsedResult) && displayValue(context.parsedResult.error)
  return toolFailureDetected(context) || directError ? { ...context, resultError: true } : null
}

function spawnedChatIds(context: ToolCardContext): string[] {
  const outcome = context.livePendingAction?.outcome
  if (!isPlainObject(outcome) || !Array.isArray(outcome.chat_ids)) return []
  return outcome.chat_ids.flatMap((id) => {
    const value = displayValue(id)
    return value ? [value] : []
  })
}

function ChatList({ chats }: { chats: ChatInput[] }) {
  if (chats.length === 0) return <EmptyState>No chats supplied.</EmptyState>
  return (
    <ol className="min-w-0 space-y-2">
      {chats.map((chat, index) => (
        <li className="min-w-0 rounded-[var(--radius-panel)] border border-border bg-surface p-2" key={index}>
          <div className="mb-1 flex min-w-0 flex-wrap items-center gap-1.5">
            <span className="min-w-0 break-words font-semibold text-text-primary">{chat.title || `Chat ${index + 1}`}</span>
            <Badge>{chat.provider || "Default provider"}</Badge>
            {chat.repository ? (
              <Badge>
                <EntityReference href={`https://github.com/${chat.repository}`} kind="repository" repositorySlug={chat.repository} />
              </Badge>
            ) : null}
          </div>
          <MarkdownPreview
            emptyLabel="No prompt supplied."
            linkifySlugs
            linkifyUrls
            maxChars={PREVIEW_CHARS}
            modalLabel={`Chat ${index + 1} prompt`}
            text={chat.prompt}
            title="Prompt"
          />
        </li>
      ))}
    </ol>
  )
}

function renderExpanded(context: ToolCardContext) {
  const failure = errorContext(context)
  if (failure) return <ToolFailureSummaryCard config={failureConfig} context={failure} />
  const pending = parsePendingActionResult(context)
  if (!pending) return null
  const chats = chatsFrom(context)
  const reason = typeof context.input?.reason === "string" ? context.input.reason : ""
  const chatIds = spawnedChatIds(context)

  return (
    <div className="min-w-0 space-y-2">
      <CardShell>
        <ChatList chats={chats} />
        <div>
          <SectionLabel>Reason</SectionLabel>
          <MarkdownPreview emptyLabel="No reason supplied." linkifySlugs linkifyUrls maxChars={PREVIEW_CHARS} modalLabel="Spawn chats reason" text={reason} />
        </div>
        {chatIds.length > 0 ? (
          <div>
            <SectionLabel>Spawned chats</SectionLabel>
            <div className="mt-1 flex min-w-0 flex-wrap gap-2">
              {chatIds.map((id) => (
                <EntityReference id={id} key={id} kind="chat" />
              ))}
            </div>
          </div>
        ) : null}
      </CardShell>
      <PendingActionResultCard result={pending} />
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const failure = errorContext(context)
  if (failure) return toolFailureCollapsedSummary(failure, failureConfig)
  const pending = parsePendingActionResult(context)
  return pending ? pendingActionCollapsedSummary(pending) : null
}

const spawnChatsToolCard: ToolCardRenderer = { toolName: "spawn_chats", collapsedSummary, renderExpanded }

export const examples: ToolCardExample[] = [
  {
    id: "pending_parallel_review",
    label: "Pending spawned chats",
    input: { chats: [{ title: "Review", prompt: "Review JOB-42", provider: "codex", repository: "acme/widgets" }], reason: "Parallel review" },
    parsedResult: {
      pending_action_group_id: 9,
      pending_action_id: 10,
      pending_confirmation_id: 10,
      state: "pending",
      member_count: 1,
      message: "Spawn 1 chat?"
    }
  }
]

export default spawnChatsToolCard
