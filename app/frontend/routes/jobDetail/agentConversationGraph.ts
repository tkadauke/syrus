// Pure layout/label helpers for the Agent Conversation tab, extracted so the
// grouping and label-generation logic (row grouping for grader_fanout,
// per-edge handoff descriptions) can be unit tested without rendering React.
//
// This is a causal thread, not a time-scaled Gantt: rows stack vertically in
// execution order and a connector's label lives in normal document flow
// between two rows, so it can wrap to fit instead of being squeezed into a
// fixed-width gap between side-by-side columns.
import type { AgentConversationEdge, AgentConversationNode } from "../../api/jobs"
import { humanize } from "./stepModel"

export type ConversationRow = AgentConversationNode[]

function sortedKey(ids: string[] | undefined): string {
  if (!ids || ids.length === 0) return ""
  return [...ids].sort().join(",")
}

// Groups adjacent deterministic_check nodes that share the exact same set of
// predecessor node ids into one row -- this is what a grader_fanout's
// materialized parallel `grader` Steps look like in the node list (they run
// side by side, then merge into one downstream node). Every other node kind
// always gets its own row, so unrelated nodes with an empty predecessor set
// are never mistaken for parallel siblings.
export function buildConversationRows(nodes: AgentConversationNode[], edges: AgentConversationEdge[]): ConversationRow[] {
  const predecessorsOf = new Map<string, string[]>()
  for (const edge of edges) {
    predecessorsOf.set(edge.to_id, [...(predecessorsOf.get(edge.to_id) ?? []), edge.from_id])
  }

  const rows: ConversationRow[] = []
  let index = 0
  while (index < nodes.length) {
    const node = nodes[index]
    if (node.kind !== "deterministic_check") {
      rows.push([node])
      index += 1
      continue
    }

    const group = [node]
    const groupKey = sortedKey(predecessorsOf.get(node.id))
    let next = index + 1
    while (
      groupKey &&
      next < nodes.length &&
      nodes[next].kind === "deterministic_check" &&
      sortedKey(predecessorsOf.get(nodes[next].id)) === groupKey
    ) {
      group.push(nodes[next])
      next += 1
    }
    rows.push(group)
    index = next
  }

  return rows
}

function nodeVerdict(node: AgentConversationNode): string | null {
  const verdict = node.detail?.verdict
  return typeof verdict === "string" && verdict.length > 0 ? verdict : null
}

function outcomeVerb(node: AgentConversationNode): string {
  if (node.state === "succeeded") return "passed"
  if (node.state === "failed") return "failed"
  return humanize(node.state || "finished")
}

function fromDescription(node: AgentConversationNode): string {
  if (node.kind === "deterministic_check") return `${node.label} ${outcomeVerb(node)}`

  if (node.kind === "agent_session") {
    const verdict = nodeVerdict(node)
    return verdict ? `${node.label} replied ${verdict}` : `${node.label} finished`
  }

  return node.summary || node.label
}

function isFailingHandoff(node: AgentConversationNode): boolean {
  if (node.kind === "deterministic_check") return node.state === "failed"
  if (node.kind === "agent_session") return nodeVerdict(node) === "needs_work"
  return false
}

function toAction(node: AgentConversationNode, failing: boolean): string {
  if (failing && node.kind === "agent_session") return `${node.label} repair requested`
  return `${node.label} started`
}

// Generated per pair of adjacent nodes/rows from their kind/label/state/
// verdict -- never a hardcoded string keyed on step name, so a new grader or
// step kind gets a sensible label for free.
export function edgeLabel(from: AgentConversationNode, to: AgentConversationNode): string {
  return `${fromDescription(from)} — ${toAction(to, isFailingHandoff(from))}`
}

export function connectorLabel(fromRow: ConversationRow, toRow: ConversationRow): string {
  if (fromRow.length > 1) {
    const total = fromRow.length
    const passed = fromRow.filter((node) => node.state === "succeeded").length
    return `${passed}/${total} checks passed — ${toAction(toRow[0], passed < total)}`
  }

  if (toRow.length > 1) {
    return `${fromDescription(fromRow[0])} — ${toRow.length} checks started`
  }

  return edgeLabel(fromRow[0], toRow[0])
}

const ROLE_AVATAR_COLORS: Record<string, string> = {
  "workflow:implement": "bg-brand",
  "workflow:rebase_conflict": "bg-orange-500",
  "workflow:summary_test_plan": "bg-teal-500",
  "workflow:adversarial_reviewer": "bg-purple-500",
  "workflow:visual_reviewer": "bg-pink-500",
  "workflow:manual": "bg-gray-500"
}

export function avatarColorClass(role: string | undefined): string {
  return (role && ROLE_AVATAR_COLORS[role]) || "bg-slate-500"
}

function detailArray(node: AgentConversationNode, key: string): Array<Record<string, unknown>> {
  const value = node.detail?.[key]
  return Array.isArray(value) ? (value as Array<Record<string, unknown>>) : []
}

function detailString(record: Record<string, unknown>, key: string): string | null {
  const value = record[key]
  return typeof value === "string" && value.length > 0 ? value : null
}

export function externalTriggerContent(node: AgentConversationNode): string | null {
  if (node.trigger_kind === "pr_comment") {
    const comments = detailArray(node, "comments")
    const latest = comments.at(-1)
    return (latest && detailString(latest, "body")) || node.summary
  }

  if (node.trigger_kind === "chat_feedback") {
    return detailString(node.detail || {}, "feedback") || node.summary
  }

  if (node.trigger_kind === "ci_failure") {
    const names = detailArray(node, "failed_checks").map((check) => detailString(check, "name")).filter((name): name is string => Boolean(name))
    return names.length > 0 ? `Failing checks: ${names.join(", ")}` : node.summary
  }

  return node.summary
}

export function externalTriggerSourceUrl(node: AgentConversationNode, prUrl: string | null): string | null {
  if (node.trigger_kind === "pr_comment") return prUrl

  if (node.trigger_kind === "ci_failure") {
    const withUrl = detailArray(node, "failed_checks").find((check) => detailString(check, "html_url"))
    return withUrl ? detailString(withUrl, "html_url") : null
  }

  return null
}

export function deterministicCommandLine(node: AgentConversationNode): string | null {
  return detailString(node.detail || {}, "command")
}

// "Raw command output only" -- the deterministic_check drawer never shows
// agent reasoning, only whatever a grader/format/generate/dependency_audit
// step actually printed.
export function deterministicRawOutput(node: AgentConversationNode): string | null {
  const detail = node.detail || {}
  const output = detailString(detail, "output")
  if (output) return output

  const failures = node.step_kind ? detailArray(node, `${node.step_kind}_failures`) : []
  if (failures.length > 0) {
    return failures.map((failure) => `$ ${detailString(failure, "command") || ""}\n${detailString(failure, "output_tail") || ""}`).join("\n\n")
  }

  if (node.step_kind === "dependency_audit" && Array.isArray(detail.results)) {
    return JSON.stringify(detail.results, null, 2)
  }

  return null
}
