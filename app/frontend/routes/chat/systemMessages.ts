// System / MCP / result message parsing helpers extracted from Chat.tsx.
//
// Turn raw assistant/system message payloads into the structured tool,
// system, and MCP-health render models the chat stream shows — including the
// init/result/mcp system cards and the duration label. Pure functions over
// the shared value utils + chat API types, so they move out of the 6k-line
// Chat.tsx; renderMessage imports structuredTool/systemMessage back.
import type { ChatCrossChatBridge, ChatMcpHealth, ChatMessageItem, ChatStructuredTool, ChatSystemMessage } from "../../api/chats"
import { batchedNoticeContents, contentRecord, formatCurrency, humanize, stringArray, stringValue } from "./utils"
import { fullResultBodyUnbounded, toolPresentation, toolResultPresentation } from "./toolRendering"
import i18n from "../../i18n"

export function structuredTool(message: ChatMessageItem): ChatStructuredTool {
  const content = contentRecord(message.content)
  const name = message.tool_name || stringValue(content?.name) || message.role
  const proposal = message.proposal
  const input = contentRecord(content?.input) || {}
  const presentation = toolPresentation(name, input)
  const resultBody = message.role === "tool_result" ? fullResultBodyUnbounded(content?.content ?? content?.result ?? message.content ?? message.text) : ""
  const resultPresentation = resultBody ? toolResultPresentation(presentation.name, resultBody, content?.is_error === true, resultBody, input) : null

  return {
    name,
    raw_name: presentation.raw_name,
    display_label: presentation.display_label,
    argument_summary: presentation.argument_summary,
    raw_payload: content || { content: message.content ?? message.text },
    result_kind: resultPresentation?.kind,
    result_summary: resultPresentation?.summary,
    summary_metadata: resultPresentation?.metadata,
    payload: content || { content: message.content ?? message.text },
    proposal_id: proposal?.id || null,
    proposal_state_label: proposal?.state === "proposed" ? "pending" : proposal?.state || null
  }
}

export function systemMessage(message: ChatMessageItem): ChatSystemMessage | null {
  const text = message.text || stringValue(contentRecord(message.content)?.text) || ""
  const crossChatBridge = crossChatBridgeSystemMessage(message, text)
  if (crossChatBridge) return crossChatBridge

  const wakeupAutomation = wakeupAutomationFromContent(message.content, text)
  if (wakeupAutomation) return wakeupAutomation

  const chatTurnRetry = chatTurnRetryFromContent(message.content, text)
  if (chatTurnRetry) return chatTurnRetry

  const providerError = providerErrorFromContent(message.content)
  if (providerError) return providerError

  const skillInvocation = skillInvocationFromContent(message.content, text)
  if (skillInvocation) return skillInvocation

  const goalContinuation = goalContinuationFromContent(message.content, text)
  if (goalContinuation) return goalContinuation

  const mcpHealth = mcpHealthFromContent(message.content)
  if (mcpHealth.length > 0) return structuredMcpMessage(mcpHealth)

  const result = text.match(/^\[(?:codex )?result\]\s+(.+)$/)
  if (result) return systemResultMessage(parseSystemFields(result[1]))

  const mcp = text.match(/^\[mcp_servers\]\s+(.+)$/)
  if (mcp) return systemMcpMessage(mcp[1])

  const toolsInit = text.match(/^\[mcp_tools_init\]\s+(.+)$/)
  if (toolsInit) return systemMcpToolsInitMessage(toolsInit[1])

  const codexError = text.match(/^\[codex error\]\s+(.+)$/)
  if (codexError) return { tone: "error", label: i18n.t("chat:system.error"), body: codexError[1] }

  if (text.startsWith("Claude API error:")) {
    return { tone: "error", label: i18n.t("chat:system.claude_api"), body: text }
  }

  if (text.startsWith("Claude authentication failed.")) {
    return {
      tone: "error",
      label: i18n.t("chat:system.claude_auth"),
      body: text,
      cta: { label: i18n.t("chat:system.open_credentials"), path: "/credentials" }
    }
  }

  const content = contentRecord(message.content)
  const bodyFormat = content?.body_format === "markdown" ? "markdown" : undefined
  const requestedTone = stringValue(content?.system_tone)
  const tone = requestedTone === "success" || requestedTone === "warning" || requestedTone === "error" ? requestedTone : "neutral"
  const label = stringValue(content?.system_label) || i18n.t("chat:system.system")
  return { tone, label, body: text, body_format: bodyFormat, prominent: content?.prominent === true }
}

// The outbound (sender-side) and hop-limit closure-notice system messages
// ChatSession::CrossChatMessage posts. The inbound (target-side) message keeps
// its existing relayed-chat bubble treatment.
export function crossChatBridgeSystemMessage(message: ChatMessageItem, text: string): ChatSystemMessage | null {
  const bridge = message.cross_chat_bridge
  if (!bridge || bridge.direction === "inbound") return null

  if (bridge.direction === "closed") {
    return { tone: "warning", label: i18n.t("chat:system.cross_chat"), body: text, body_format: "markdown" }
  }

  return {
    tone: "neutral",
    label: i18n.t("chat:system.cross_chat"),
    body: text,
    body_format: "markdown",
    cta: { label: crossChatBridgeLinkLabel(bridge), path: `/chats/${bridge.counterpart_chat_session_id}` }
  }
}

export function wakeupAutomationFromContent(content: unknown, text: string): ChatSystemMessage | null {
  const record = contentRecord(content)
  if (record?.requested_by !== "wakeup") return null

  return { tone: "neutral", label: i18n.t("chat:system.automation"), body: text || stringValue(record.text) || i18n.t("chat:system.wakeup_fired") }
}

export function chatTurnRetryFromContent(content: unknown, text: string): ChatSystemMessage | null {
  const record = contentRecord(content)
  if (record?.source !== "chat_turn_retry") return null

  return { tone: "neutral", label: i18n.t("chat:system.retry"), body: text || stringValue(record.text) || i18n.t("chat:system.retrying_turn") }
}

// Mirrors the inbound badge's i18n `cross_chat_bridge_link` fallback
// (MessageCards.tsx, `counterpart_chat_title || t("new_title")`) so an
// untitled counterpart chat renders the same "New chat" label on both sides
// of the bridge instead of silently dropping the title segment here.
export function crossChatBridgeLinkLabel(bridge: ChatCrossChatBridge) {
  return i18n.t("chat:system.via_chat", { id: bridge.counterpart_chat_session_id, title: bridge.counterpart_chat_title || i18n.t("chat:new_title") })
}

export function goalContinuationFromContent(content: unknown, text: string): ChatSystemMessage | null {
  const record = contentRecord(content)
  const goalNoticeContents = batchedNoticeContents(record).filter(goalContinuationContent)
  if (!goalContinuationContent(record) && goalNoticeContents.length === 0) return null

  const body = goalNoticeContents
    .map((notice) => stringValue(notice.text))
    .filter(Boolean)
    .join("\n\n")

  return { tone: "neutral", label: i18n.t("chat:system.goal"), body: body || text || i18n.t("chat:system.goal_continuation_started") }
}

function goalContinuationContent(content: Record<string, unknown> | null) {
  return content?.source === "goal_continuation" || content?.goal_continuation === true
}

export function providerErrorFromContent(content: unknown): ChatSystemMessage | null {
  const payload = contentRecord(content)?.provider_error
  const record = contentRecord(payload)
  if (!record) return null

  const kind = stringValue(record.kind)
  const provider = stringValue(record.provider)
  const model = stringValue(record.model)
  const detail = stringValue(record.detail)
  const halted = record.halted === true
  const scope = [provider, model].filter(Boolean).join(" ") || "provider/model"

  if (kind === "provider_usage_limit") {
    return {
      tone: "warning",
      label: i18n.t("chat:system.usage_limit"),
      body: i18n.t("chat:system.usage_limit_body", { scope, detail }),
      prominent: true
    }
  }

  return {
    tone: "error",
    label: halted ? i18n.t("chat:system.provider_halted") : i18n.t("chat:system.agent_error"),
    body: detail || i18n.t("chat:system.agent_turn_failed"),
    prominent: true
  }
}

export function skillInvocationFromContent(content: unknown, text: string): ChatSystemMessage | null {
  const record = contentRecord(contentRecord(content)?.skill_invocation)
  if (!record) return null

  return { tone: "warning", label: i18n.t("chat:system.skill"), body: text }
}

export function structuredMcpMessage(servers: ChatMcpHealth[]): ChatSystemMessage | null {
  const unavailable = servers.filter((server) => server.unavailable_tools.length > 0)

  if (unavailable.length > 0) {
    return {
      tone: "warning",
      label: i18n.t("chat:system.mcp_unavailable"),
      body: i18n.t("chat:system.mcp_unavailable_body", { servers: serverStatusList(unavailable), tools: toolSummary(unavailable, "unavailable_tools") })
    }
  }

  return null
}

export function serverStatusList(servers: ChatMcpHealth[]) {
  return servers.map((server) => `${server.name} ${server.status || "unknown"}`).join(", ")
}

export function toolSummary(servers: ChatMcpHealth[], key: "available_tools" | "pending_tools" | "unavailable_tools") {
  const names = Array.from(new Set(servers.flatMap((server) => server[key] || [])))
  if (names.length === 0) return i18n.t("chat:system.none_reported")
  if (names.length <= 4) return names.join(", ")

  return i18n.t("chat:system.more_tools", { names: names.slice(0, 4).join(", "), count: names.length - 4 })
}

export function mcpHealthFromContent(content: unknown): ChatMcpHealth[] {
  const raw = contentRecord(content)?.mcp_health
  if (!Array.isArray(raw)) return []

  return raw
    .map((item) => {
      const record = contentRecord(item)
      if (!record) return null

      return {
        name: stringValue(record.name),
        status: stringValue(record.status) || "unknown",
        available_tools: stringArray(record.available_tools),
        pending_tools: stringArray(record.pending_tools),
        unavailable_tools: stringArray(record.unavailable_tools)
      }
    })
    .filter((item): item is ChatMcpHealth => item != null && item.name.length > 0)
}

export function systemResultMessage(fields: Record<string, string>): ChatSystemMessage {
  const error = fields.is_error === "true"
  const subtype = fields.subtype || ""
  const body = [systemResultTitle(error, subtype)]
  if (fields.turns) body.push(i18n.t("chat:system.turn_count", { count: Number.parseInt(fields.turns, 10) }))
  if (fields.duration_ms) body.push(systemDurationLabel(fields.duration_ms))
  if (fields.total_cost_usd) body.push(formatCurrency(Number.parseFloat(fields.total_cost_usd)))

  return { tone: error ? "error" : "success", label: error ? i18n.t("chat:system.failed") : i18n.t("chat:system.done"), body: body.join(" · ") }
}

export function systemResultTitle(error: boolean, subtype: string) {
  if (error)
    return subtype && subtype !== "success"
      ? i18n.t("chat:system.agent_run_failed_detail", { detail: humanize(subtype) })
      : i18n.t("chat:system.agent_run_failed")
  if (subtype === "success") return i18n.t("chat:system.agent_run_succeeded")

  return subtype ? i18n.t("chat:system.agent_run_finished_detail", { detail: humanize(subtype) }) : i18n.t("chat:system.agent_run_finished")
}

export function systemMcpMessage(payload: string): ChatSystemMessage {
  const servers = payload
    .split(/\s*,\s*/)
    .map((entry) => {
      const [name, status] = entry.split("=", 2)
      return name ? [name, status || "unknown"] : null
    })
    .filter((entry): entry is [string, string] => entry != null)
  const ready = new Set(["connected", "running", "ready"])
  const transient = new Set(["pending"])
  const pending = servers.filter(([, status]) => transient.has(status))
  const failing = servers.filter(([, status]) => !ready.has(status) && !transient.has(status))

  if (servers.length === 0) return { tone: "neutral", label: "MCP", body: i18n.t("chat:system.mcp_status_unavailable") }
  if (failing.length > 0)
    return {
      tone: "warning",
      label: "MCP",
      body: i18n.t("chat:system.mcp_issue", { servers: failing.map(([name, status]) => `${name} ${status}`).join(", ") })
    }
  if (pending.length > 0)
    return { tone: "neutral", label: "MCP", body: i18n.t("chat:system.mcp_starting", { servers: pending.map(([name]) => name).join(", ") }) }

  return {
    tone: "success",
    label: i18n.t("chat:system.connected"),
    body: i18n.t("chat:system.mcp_connected", { servers: servers.map(([name]) => name).join(", ") })
  }
}

export function systemMcpToolsInitMessage(payload: string): ChatSystemMessage {
  const fields = parseSystemFields(payload)
  const count = Number.parseInt(fields.count || "", 10)
  const required =
    payload
      .match(/(?:^|\s)required=([^\s]*)/)?.[1]
      .split(",")
      .filter(Boolean) || []
  const pieces = [Number.isFinite(count) ? i18n.t("chat:system.mcp_tool_count", { count }) : i18n.t("chat:system.mcp_tools_available")]

  if (required.length > 0)
    pieces.push(
      i18n.t("chat:system.required_tools", {
        names: required.slice(0, 4).join(", "),
        extra: required.length > 4 ? i18n.t("chat:system.more_count", { count: required.length - 4 }) : ""
      })
    )

  return { tone: "success", label: i18n.t("chat:system.mcp_tools"), body: pieces.join(" · ") }
}

export function parseSystemFields(payload: string) {
  return Object.fromEntries(Array.from(payload.matchAll(/(\w+)=([^,\s]+)/g), (match) => [match[1], match[2]]))
}

export function systemDurationLabel(durationMs: string) {
  const seconds = Number.parseFloat(durationMs) / 1000
  if (seconds < 60) return `${Math.round(seconds * 10) / 10}s`

  const minutes = seconds / 60
  if (minutes < 10) return `${Math.round(minutes * 10) / 10}m`

  return `${Math.round(minutes)}m`
}
