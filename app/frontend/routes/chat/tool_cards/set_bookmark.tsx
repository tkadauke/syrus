import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CopyableSlug } from "../../../components/CopyableSlug"
import { Badge, displayValue, Row } from "../toolCardUi"
import { ErrorCard, MalformedCard, StatusCard, successOrError } from "../chatHelperToolCard"

// Core-owned tool card for set_bookmark. Supersedes the legacy
// typedToolResult("set_bookmark") special case in toolRendering.ts (same
// migration read_job/propose_job already went through).
type SetBookmarkResult = {
  id: string | null
  label: string
  kind: string | null
  messageId: string | null
  anchor: string | null
}

function parseResult(context: ToolCardContext) {
  const input = isPlainObject(context.input) ? context.input : {}

  return successOrError<SetBookmarkResult>(context, "Bookmark creation failed.", (parsed) => {
    const label = displayValue(parsed.label) ?? displayValue(input.label)
    if (!label) return null

    return {
      id: displayValue(parsed.id),
      label,
      kind: displayValue(parsed.kind) ?? displayValue(input.kind),
      messageId: displayValue(parsed.message_id),
      anchor: displayValue(parsed.anchor)
    }
  })
}

function collapsedSummary(context: ToolCardContext) {
  const parsed = parseResult(context)
  if (parsed.kind === "error") return "Bookmark creation failed"
  if (parsed.kind === "malformed") return "Bookmark returned an unexpected response"
  const result = parsed.data

  return `Bookmark added: ${result.label}${result.kind ? ` (${result.kind})` : ""}`
}

function renderExpanded(context: ToolCardContext) {
  const parsed = parseResult(context)
  if (parsed.kind === "error") return <ErrorCard title="Bookmark" message={parsed.message} />
  if (parsed.kind === "malformed") return <MalformedCard title="Bookmark" />
  const result = parsed.data
  const targetAnchor = result.anchor ?? (result.messageId ? `message-${result.messageId}` : null)
  const href = context.chatSessionId != null && targetAnchor ? `#${encodeURIComponent(targetAnchor.replace(/^#/, ""))}` : null

  return (
    <StatusCard title="Bookmark" status="added">
      <div className="flex flex-wrap items-center gap-2">
        {result.kind ? <Badge>{result.kind}</Badge> : null}
        {result.id ? <Badge>#{result.id}</Badge> : null}
      </div>
      <div className="grid min-w-0 gap-2 sm:grid-cols-2">
        <Row label="Label" value={result.label} />
        {result.anchor ? <BookmarkReference href={href} label="Anchor" value={result.anchor} /> : null}
        {result.messageId ? <BookmarkReference href={href} label="Message" value={`#${result.messageId}`} /> : null}
      </div>
    </StatusCard>
  )
}

function BookmarkReference({ href, label, value }: { href: string | null; label: string; value: string }) {
  return (
    <div className="min-w-0">
      <div className="text-2xs font-medium uppercase tracking-wide text-text-subtle">{label}</div>
      {href ? (
        <a className="break-all font-mono text-xs font-medium text-brand hover:underline dark:text-brand-emphasis" href={href}>
          {value}
        </a>
      ) : (
        <CopyableSlug className="text-xs" slug={value} />
      )}
    </div>
  )
}

const setBookmarkToolCard: ToolCardRenderer = {
  toolName: "set_bookmark",
  collapsedSummary,
  renderExpanded
}

export const examples: ToolCardExample[] = [
  {
    id: "topic_bookmark",
    label: "Topic bookmark",
    input: { label: "Launch notes", kind: "topic" },
    parsedResult: { id: 4, label: "Launch notes", kind: "topic", message_id: 12, anchor: "message-12" }
  },
  {
    id: "input_fallback",
    label: "Result omits input fields",
    input: { label: "Epic kickoff", kind: "epic_origin" },
    parsedResult: { id: 5, message_id: 18, anchor: "message-18" }
  },
  { id: "error", label: "Bookmark error", input: { label: "Nothing yet", kind: "topic" }, resultBody: "cannot bookmark an empty chat", resultError: true },
  { id: "pending", label: "Pending result", input: { label: "Waiting for result", kind: "topic" }, parsedResult: null },
  { id: "empty", label: "Empty success response", parsedResult: {} }
]

export default setBookmarkToolCard
