// System / MCP / result message parsing helpers extracted from Chat.tsx.
//
// Turn raw assistant/system message payloads into the structured tool,
// system, and MCP-health render models the chat stream shows — including the
// init/result/mcp system cards and the duration label. Pure functions over
// the shared value utils + chat API types, so they move out of the 6k-line
// Chat.tsx; renderMessage imports structuredTool/systemMessage back.
import type { ChatMcpHealth, ChatMessageItem, ChatStructuredTool, ChatSystemMessage } from "../../api/chats"
import { contentRecord, formatCurrency, humanize, stringArray, stringValue } from "./utils"

export function structuredTool(message: ChatMessageItem): ChatStructuredTool {
  const content = contentRecord(message.content)
  const name = message.tool_name || stringValue(content?.name) || message.role
  const proposal = message.proposal

  return {
    name,
    payload: content || { content: message.content ?? message.text },
    proposal_id: proposal?.id || null,
    proposal_state_label: proposal?.state === "proposed" ? "pending" : proposal?.state || null
  }
}

export function systemMessage(message: ChatMessageItem): ChatSystemMessage | null {
  const text = message.text || stringValue(contentRecord(message.content)?.text) || ""
  const providerError = providerErrorFromContent(message.content)
  if (providerError) return providerError

  const mcpHealth = mcpHealthFromContent(message.content)
  if (mcpHealth.length > 0) return structuredMcpMessage(mcpHealth)

  const result = text.match(/^\[(?:codex )?result\]\s+(.+)$/)
  if (result) return systemResultMessage(parseSystemFields(result[1]))

  const mcp = text.match(/^\[mcp_servers\]\s+(.+)$/)
  if (mcp) return systemMcpMessage(mcp[1])

  const codexError = text.match(/^\[codex error\]\s+(.+)$/)
  if (codexError) return { tone: "error", label: "Error", body: codexError[1] }

  if (text.startsWith("Claude API error:")) {
    return { tone: "error", label: "Claude API", body: text }
  }

  if (text.startsWith("Claude authentication failed.")) {
    return {
      tone: "error",
      label: "Claude auth",
      body: text,
      cta: { label: "Open Credentials", path: "/credentials" }
    }
  }

  return { tone: "neutral", label: "System", body: text }
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
      label: "Usage limit",
      body: `Syrus halted work for ${scope}: usage limit or quota exhausted. ${detail}`,
      prominent: true
    }
  }

  return {
    tone: "error",
    label: halted ? "Provider halted" : "Agent error",
    body: detail || "Agent turn failed.",
    prominent: true
  }
}

export function structuredMcpMessage(servers: ChatMcpHealth[]): ChatSystemMessage | null {
  const unavailable = servers.filter((server) => server.unavailable_tools.length > 0)

  if (unavailable.length > 0) {
    return {
      tone: "warning",
      label: "MCP unavailable",
      body: `MCP unavailable: ${serverStatusList(unavailable)}. Tools unavailable: ${toolSummary(unavailable, "unavailable_tools")}. Retry the turn or check the chat sidecar logs before asking the agent to persist proposals, schedules, bookmarks, or whiteboard edits.`
    }
  }

  return null
}

export function serverStatusList(servers: ChatMcpHealth[]) {
  return servers.map((server) => `${server.name} ${server.status || "unknown"}`).join(", ")
}

export function toolSummary(servers: ChatMcpHealth[], key: "available_tools" | "pending_tools" | "unavailable_tools") {
  const names = Array.from(new Set(servers.flatMap((server) => server[key] || [])))
  if (names.length === 0) return "none reported"
  if (names.length <= 4) return names.join(", ")

  return `${names.slice(0, 4).join(", ")} +${names.length - 4} more`
}

export function mcpHealthFromContent(content: unknown): ChatMcpHealth[] {
  const raw = contentRecord(content)?.mcp_health
  if (!Array.isArray(raw)) return []

  return raw.map((item) => {
    const record = contentRecord(item)
    if (!record) return null

    return {
      name: stringValue(record.name),
      status: stringValue(record.status) || "unknown",
      available_tools: stringArray(record.available_tools),
      pending_tools: stringArray(record.pending_tools),
      unavailable_tools: stringArray(record.unavailable_tools)
    }
  }).filter((item): item is ChatMcpHealth => item != null && item.name.length > 0)
}

export function systemResultMessage(fields: Record<string, string>): ChatSystemMessage {
  const error = fields.is_error === "true"
  const subtype = fields.subtype || ""
  const body = [systemResultTitle(error, subtype)]
  if (fields.turns) body.push(`${Number.parseInt(fields.turns, 10)} ${Number.parseInt(fields.turns, 10) === 1 ? "turn" : "turns"}`)
  if (fields.duration_ms) body.push(systemDurationLabel(fields.duration_ms))
  if (fields.total_cost_usd) body.push(formatCurrency(Number.parseFloat(fields.total_cost_usd)))

  return { tone: error ? "error" : "success", label: error ? "Failed" : "Done", body: body.join(" · ") }
}

export function systemResultTitle(error: boolean, subtype: string) {
  if (error) return `Agent run failed${subtype && subtype !== "success" ? `: ${humanize(subtype)}` : ""}`
  if (subtype === "success") return "Agent run succeeded"

  return subtype ? `Agent run finished: ${humanize(subtype)}` : "Agent run finished"
}

export function systemMcpMessage(payload: string): ChatSystemMessage {
  const servers = payload.split(/\s*,\s*/).map((entry) => {
    const [name, status] = entry.split("=", 2)
    return name ? [name, status || "unknown"] : null
  }).filter((entry): entry is [string, string] => entry != null)
  const ready = new Set(["connected", "running", "ready"])
  const transient = new Set(["pending"])
  const pending = servers.filter(([, status]) => transient.has(status))
  const failing = servers.filter(([, status]) => !ready.has(status) && !transient.has(status))

  if (servers.length === 0) return { tone: "neutral", label: "MCP", body: "MCP server status unavailable" }
  if (failing.length > 0) return { tone: "warning", label: "MCP", body: `MCP issue: ${failing.map(([name, status]) => `${name} ${status}`).join(", ")}` }
  if (pending.length > 0) return { tone: "neutral", label: "MCP", body: `MCP starting: ${pending.map(([name]) => name).join(", ")}` }

  return { tone: "success", label: "Connected", body: `MCP connected: ${servers.map(([name]) => name).join(", ")}` }
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
