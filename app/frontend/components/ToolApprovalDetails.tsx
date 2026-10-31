import { useState } from "react"
import { Avatar } from "./Avatar"
import { redactToolCardValue } from "../toolCardSecurity"
import { toolPresentationEntryFor } from "../toolPresentationRegistry"
import { useT } from "../hooks/useT"

export type ToolApprovalActor = {
  name?: string | null
  handle?: string | null
  avatar_key?: string | null
  avatar_url?: string | null
  accent_hex?: string | null
}

const LONG_VALUE_LENGTH = 240

function ReadableValue({ value }: { value: unknown }) {
  const { t } = useT("chat")
  const [expanded, setExpanded] = useState(false)
  const text = typeof value === "string" ? value : JSON.stringify(value, null, 2)
  const missing = value === undefined || value === null || text === undefined
  if (missing) return <span className="italic text-text-tertiary">{t("tool_approval_not_provided")}</span>
  const long = text.length > LONG_VALUE_LENGTH
  const visible = long && !expanded ? `${text.slice(0, LONG_VALUE_LENGTH)}…` : text
  return (
    <div>
      <pre className="whitespace-pre-wrap break-words font-mono text-xs text-text-primary">{visible}</pre>
      {long ? (
        <button className="mt-1 text-xs font-medium text-brand hover:underline" onClick={() => setExpanded((value) => !value)} type="button">
          {expanded ? t("tool_approval_show_less") : t("tool_approval_show_more")}
        </button>
      ) : null}
    </div>
  )
}

export function ToolApprovalDetails({ toolName, args, actor }: { toolName?: string | null; args?: unknown; actor?: ToolApprovalActor | null }) {
  const { t } = useT("chat")
  const safeArgs = redactToolCardValue(args)
  const objectArgs = safeArgs && typeof safeArgs === "object" && !Array.isArray(safeArgs) ? (safeArgs as Record<string, unknown>) : {}
  const entries = Object.entries(objectArgs)
  const presentation = toolPresentationEntryFor(toolName || "unknown")
  const customSummary = presentation.argumentSummary(objectArgs)

  return (
    <div className="space-y-3">
      {actor ? (
        <div className="flex items-center gap-2">
          <Avatar
            name={actor.name || actor.handle || t("tool_approval_coworker")}
            avatarKey={actor.avatar_key}
            avatarUrl={actor.avatar_url}
            accentHex={actor.accent_hex}
            size="sm"
          />
          <div className="min-w-0 text-sm">
            <span className="font-medium text-text-primary">{actor.name || actor.handle || t("tool_approval_coworker")}</span>
            {actor.handle ? <span className="ml-1 text-text-secondary">@{actor.handle}</span> : null}
          </div>
        </div>
      ) : null}
      <div>
        <div className="text-sm font-semibold text-text-primary">{presentation.displayLabel}</div>
        {customSummary && customSummary.length <= LONG_VALUE_LENGTH ? <div className="mt-0.5 text-xs text-text-secondary">{customSummary}</div> : null}
      </div>
      {entries.length ? (
        <dl className="divide-y divide-border rounded border border-border bg-surface-subtle">
          {entries.map(([key, value]) => (
            <div className="grid gap-1 p-3 sm:grid-cols-[10rem_minmax(0,1fr)]" key={key}>
              <dt className="text-xs font-medium text-text-secondary">{key.replaceAll("_", " ")}</dt>
              <dd className="min-w-0">
                <ReadableValue value={value} />
              </dd>
            </div>
          ))}
        </dl>
      ) : (
        <p className="text-xs italic text-text-tertiary">{t("tool_approval_no_arguments")}</p>
      )}
    </div>
  )
}
