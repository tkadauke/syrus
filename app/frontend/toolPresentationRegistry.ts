// Unified tool presentation registry — the single contract both existing
// ToolCardRenderer modules (pluginToolCards.tsx) and non-MCP provider
// built-in presentation logic (toolRendering.ts's Bash/Read/Grep/WebSearch
// handling) are described through. This is the identity/metadata layer the
// Tool Card Catalog (a later Job) renders from; it deliberately does not
// duplicate rendering behavior itself — every field here composes an
// existing, already-centralized implementation instead of re-deriving it,
// so collapse state, redaction, envelope normalization, and grouping stay
// owned by their current homes (toolRendering.ts, toolCardSecurity.ts,
// streamBuilders.ts) rather than forking a second copy per entry.
import { discoveredToolCardEntries, type ToolCardExample, type ToolCardOwner, type ToolCardRenderer } from "./pluginToolCards"
import { normalizedToolName, simpleToolProgressLabel, toolDetail, toolLabel } from "./routes/chat/toolRendering"

export type ToolOwnerType = ToolCardOwner["ownerType"] | "provider"

export type ToolSourceType =
  | "mcp_tool"
  | "provider_builtin"
  | "local_mode_tool"
  | "chat_surface_component"
  | "fallback_only"

// Re-exported under the registry's own name: card modules declare examples
// against pluginToolCards.tsx's ToolCardExample (the lower-level discovery
// contract), and every other registry consumer sees the same shape as
// ToolPresentationExample.
export type ToolPresentationExample = ToolCardExample

export type ToolPresentationEntry = {
  // Canonical, normalized tool name (see normalizedToolName) — what every
  // other field is keyed on and what a card's own `toolName` declares.
  toolName: string
  // Alternate raw names that resolve to this entry (a rename, or two CLI
  // tool names that share one presentation, e.g. Task/Agent below).
  aliases: string[]
  ownerType: ToolOwnerType
  ownerName: string
  sourceType: ToolSourceType
  readOnly: boolean
  displayLabel: string
  progressLabel: string
  argumentSummary: (input?: Record<string, unknown>) => string
  renderer: ToolCardRenderer | null
  examples: ToolPresentationExample[]
}

// Same read-only/side-effect heuristic streamBuilders.ts used to keep as its
// own private copy (READ_ONLY_TOOLS + a name-prefix pattern, with a second
// SIDE_EFFECTING_TOOLS set that never actually changed the outcome — every
// name in it already failed the read-only check). Centralized here as the
// registry's classification axis; streamBuilders.ts now delegates to
// isReadOnlyToolName instead of keeping a second definition.
const KNOWN_READ_ONLY_TOOL_NAMES = new Set([
  "Read", "Glob", "Grep", "WebFetch", "WebSearch", "ToolSearch",
  "list_chat_media", "read_live_state", "read_memory", "search_memories",
  "list_memories", "list_design_docs", "read_design_doc"
])
const READ_ONLY_NAME_PATTERN = /^(list|read|search|get)_/

export function isReadOnlyToolName(name: string): boolean {
  const normalized = normalizedToolName(name)
  if (KNOWN_READ_ONLY_TOOL_NAMES.has(normalized)) return true
  return READ_ONLY_NAME_PATTERN.test(normalized)
}

function builtin(toolName: string, options: { aliases?: string[]; readOnly: boolean } = { readOnly: false }): ToolPresentationEntry {
  return {
    toolName,
    aliases: options.aliases ?? [],
    ownerType: "provider",
    // The agent CLI vocabulary currently wired into chat (Claude's built-in
    // tool names). A provider whose CLI uses different names for the same
    // concept (e.g. a future Codex-specific mapping) registers its own
    // entries rather than overloading this one.
    ownerName: "claude",
    sourceType: "provider_builtin",
    readOnly: options.readOnly,
    displayLabel: toolLabel(toolName),
    progressLabel: simpleToolProgressLabel(toolName),
    argumentSummary: (input = {}) => toolDetail(toolName, input),
    renderer: null,
    examples: []
  }
}

// Claude's built-in (non-MCP) tools — the "provider built-in presentation
// logic" half of the registry contract. Task and Agent are the same
// subagent-invocation concept under two names (toolRendering.ts's
// toolArgumentSummary already groups them in one switch case); registering
// Agent as an alias of Task means alias resolution actually does something
// on a real, existing case instead of an invented one.
//
// Codex has no separate built-in vocabulary of its own to register here: its
// MCP tool calls go through the same syrus-mcp-sidecar entries above, and
// its one non-MCP built-in — running a shell command — is the same concept
// as Claude's Bash under two different raw names. `CodexInvocation` persists
// it as chat tool_name "bash" (see
// plugins/codex_agent/app/services/codex_invocation.rb); the workflow-Run
// transcript path (`CodexAgent::TranscriptEvents`) instead emits the literal
// item type name, "command_execution". Both alias to this one Bash entry
// rather than duplicating it as a separate provider entry, so the two
// providers "resolve consistently" (same canonical name, display label,
// progress label, and argument summary) regardless of which raw name a
// given transcript happened to carry.
const PROVIDER_BUILTIN_ENTRIES: ToolPresentationEntry[] = [
  builtin("Bash", { aliases: ["bash", "command_execution"], readOnly: false }),
  builtin("Read", { readOnly: true }),
  builtin("Edit", { readOnly: false }),
  builtin("MultiEdit", { readOnly: false }),
  builtin("Write", { readOnly: false }),
  builtin("NotebookEdit", { readOnly: false }),
  builtin("Glob", { readOnly: true }),
  builtin("Grep", { readOnly: true }),
  builtin("WebFetch", { readOnly: true }),
  builtin("WebSearch", { readOnly: true }),
  builtin("TodoWrite", { readOnly: false }),
  builtin("Task", { aliases: ["Agent"], readOnly: false }),
  builtin("ToolSearch", { readOnly: true })
]

// Tools that are technically ordinary MCP tools (same sidecar, same
// tool_use/tool_result envelope) but exist specifically to manage a Local
// Mode session, not general Syrus state — worth its own source type so a
// future catalog filter can separate "talks to Local Mode" from "everything
// else the chat MCP surface exposes." Overrides only sourceType/ownerType;
// rendering (and whether a card exists at all) still comes from whatever
// card discovery already found for that tool name, or the generic fallback
// if none did.
const LOCAL_MODE_TOOL_NAMES = new Set([
  "open_in_local_mode",
  "cancel_local_mode",
  "reset_workspace",
  "complete_implement_step",
  "submit_coding_changes"
])

// Components rendered directly from a chat message's own shape (a
// chat_proposal's `item.proposal`, a pending action's `item.pending_action`
// — see MessageCards.tsx's ChatMessage) rather than dispatched from a
// tool_use/tool_result pair. These aren't looked up by a real tool name —
// nothing in a transcript is ever literally named "proposal_card" — but the
// catalog still wants them representable so an operator can review every
// chat-visible presentation in one place, per the Epic.
const CHAT_SURFACE_COMPONENT_ENTRIES: ToolPresentationEntry[] = [
  {
    toolName: "proposal_card",
    aliases: [],
    ownerType: "core",
    ownerName: "core",
    sourceType: "chat_surface_component",
    readOnly: true,
    displayLabel: "Proposal",
    progressLabel: "Reviewing proposal...",
    argumentSummary: () => "Chat proposal outcome",
    renderer: null,
    examples: []
  },
  {
    toolName: "pending_action_card",
    aliases: [],
    ownerType: "core",
    ownerName: "core",
    sourceType: "chat_surface_component",
    readOnly: true,
    displayLabel: "Pending action",
    progressLabel: "Awaiting confirmation...",
    argumentSummary: () => "Chat pending action",
    renderer: null,
    examples: []
  }
]

function mcpToolEntryFor(discovered: { renderer: ToolCardRenderer; owner: ToolCardOwner; examples: ToolCardExample[] }): ToolPresentationEntry {
  const { renderer, owner, examples } = discovered
  const toolName = renderer.toolName
  return {
    toolName,
    aliases: [],
    ownerType: owner.ownerType,
    ownerName: owner.ownerName,
    sourceType: "mcp_tool",
    readOnly: isReadOnlyToolName(toolName),
    displayLabel: toolLabel(toolName),
    progressLabel: simpleToolProgressLabel(toolName),
    argumentSummary: (input = {}) => toolDetail(toolName, input),
    renderer,
    examples
  }
}

function fallbackEntryFor(toolName: string): ToolPresentationEntry {
  return {
    toolName,
    aliases: [],
    ownerType: "core",
    ownerName: "core",
    sourceType: "fallback_only",
    readOnly: isReadOnlyToolName(toolName),
    displayLabel: toolLabel(toolName),
    progressLabel: simpleToolProgressLabel(toolName),
    argumentSummary: (input = {}) => toolDetail(toolName, input),
    renderer: null,
    examples: []
  }
}

// A Local Mode tool's classification must hold even when no card renderer
// was ever registered for it (complete_implement_step, submit_coding_changes,
// and reset_workspace are all explicitly cardless — see
// Admin::McpToolCardCoverage::EXPLICIT_CARD_STATUSES on the backend), so this
// runs as its own pass rather than as an inline branch inside
// mcpToolEntryFor, which only ever sees names a renderer was discovered for.
function withLocalModeOverrides(entries: ToolPresentationEntry[]): ToolPresentationEntry[] {
  const byToolName = new Map(entries.map((entry) => [entry.toolName, entry]))
  const overridden = entries.map((entry) => (
    LOCAL_MODE_TOOL_NAMES.has(entry.toolName) ? { ...entry, sourceType: "local_mode_tool" as const } : entry
  ))

  const synthesized = Array.from(LOCAL_MODE_TOOL_NAMES)
    .filter((name) => !byToolName.has(name))
    .map((name) => ({ ...fallbackEntryFor(name), sourceType: "local_mode_tool" as const }))

  return [...overridden, ...synthesized]
}

function buildRegistry(): ToolPresentationEntry[] {
  const mcpEntries = withLocalModeOverrides(discoveredToolCardEntries.map(mcpToolEntryFor))
  return [...mcpEntries, ...PROVIDER_BUILTIN_ENTRIES, ...CHAT_SURFACE_COMPONENT_ENTRIES]
}

let cachedEntries: ToolPresentationEntry[] | null = null
let cachedAliasIndex: Map<string, string> | null = null

function registryEntries(): ToolPresentationEntry[] {
  if (!cachedEntries) cachedEntries = buildRegistry()
  return cachedEntries
}

function aliasIndex(): Map<string, string> {
  if (cachedAliasIndex) return cachedAliasIndex

  cachedAliasIndex = new Map()
  for (const entry of registryEntries()) {
    for (const alias of entry.aliases) cachedAliasIndex.set(alias, entry.toolName)
  }
  return cachedAliasIndex
}

// Every entry the registry currently knows about — core/plugin MCP cards,
// provider built-ins, and chat surface components. Intended for the Tool
// Card Catalog page (a later Job); exported here so that page never has to
// re-implement discovery.
export function allToolPresentationEntries(): ToolPresentationEntry[] {
  return registryEntries()
}

// Resolve any raw tool identifier (an mcp__ prefixed name, a sidecar-prefixed
// name, a registered alias, or an already-canonical name) to its
// presentation entry. Always returns an entry — a name nothing above
// recognizes gets a generic fallback_only entry built from the same
// centralized label/progress-label/argument-summary logic every other
// entry uses, so callers never need a null check to keep rendering.
export function toolPresentationEntryFor(rawName: string): ToolPresentationEntry {
  const normalized = normalizedToolName(rawName)
  const canonicalName = aliasIndex().get(normalized) ?? normalized
  const found = registryEntries().find((entry) => entry.toolName === canonicalName)
  return found ?? fallbackEntryFor(normalized)
}
