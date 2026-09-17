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

export type ToolSourceType = "mcp_tool" | "provider_builtin" | "local_mode_tool" | "chat_surface_component" | "fallback_only"

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
  "Read",
  "Glob",
  "Grep",
  "WebFetch",
  "WebSearch",
  "ToolSearch",
  "list_chat_media",
  "read_live_state",
  "read_memory",
  "search_memories",
  "list_memories",
  "list_design_docs",
  "read_design_doc"
])
const READ_ONLY_NAME_PATTERN = /^(list|read|search|get)_/

export function isReadOnlyToolName(name: string): boolean {
  const normalized = normalizedToolName(name)
  if (KNOWN_READ_ONLY_TOOL_NAMES.has(normalized)) return true
  return READ_ONLY_NAME_PATTERN.test(normalized)
}

function builtin(
  toolName: string,
  options: { aliases?: string[]; readOnly: boolean; examples?: ToolPresentationExample[] } = { readOnly: false }
): ToolPresentationEntry {
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
    examples: options.examples ?? []
  }
}

// Provider-builtin example fixtures. Unlike MCP tool cards (whose examples
// live beside the card renderer), these have no card module to live beside
// -- Bash/Read/Grep/WebSearch render through the generic provider body, not
// a registered ToolCardRenderer -- so they're declared here, next to the
// entries they describe. Bash carries both a Claude-shaped and a
// Codex-shaped example (see the PROVIDER_BUILTIN_ENTRIES comment above for
// why the two providers share one canonical entry) to cover the
// acceptance criteria's Codex-envelope case.
const BASH_EXAMPLES: ToolPresentationExample[] = [
  {
    id: "list_repo_root_claude",
    label: "List the repo root (Claude)",
    input: { command: "ls" },
    resultBody: "app\nbin\nconfig\ndb\nlib\nplugins\nspec\nvendor",
    sourceType: "claude"
  },
  {
    id: "list_repo_root_codex",
    label: "List the repo root (Codex)",
    description:
      "Codex's command_execution item carries plain stdout text as `output`, not a Claude-style content-block array -- same canonical Bash entry, different provider envelope (see CodexAgent::TranscriptEvents).",
    input: { command: "ls -la" },
    resultBody:
      "total 8\ndrwxr-xr-x  9 root root 4096 Sep 16 20:00 .\ndrwxr-xr-x  3 root root 4096 Sep 16 19:58 ..\ndrwxr-xr-x  2 root root 4096 Sep 16 20:00 app",
    sourceType: "codex"
  },
  {
    id: "command_failed",
    label: "Error: command failed",
    input: { command: "bin/rspec spec/models/job_spec.rb" },
    resultError: true,
    resultBody: "Failures:\n\n  1) Job#approve! transitions to approved\n     Failure/Error: job.approve!\n\n1 example, 1 failure",
    sourceType: "claude"
  }
]

const READ_EXAMPLES: ToolPresentationExample[] = [
  {
    id: "read_ruby_file",
    label: "Read a Ruby file",
    input: { file_path: "app/models/job.rb" },
    resultBody:
      "     1\tclass Job < ApplicationRecord\n     2\t  include AASM\n     3\t\n     4\t  aasm column: :state do\n     5\t    state :open, initial: true"
  },
  {
    id: "read_empty_file",
    label: "Empty file",
    input: { file_path: "config/initializers/.keep" },
    resultBody: ""
  }
]

const GREP_EXAMPLES: ToolPresentationExample[] = [
  {
    id: "grep_matches",
    label: "Matches found",
    input: { pattern: "def approve!", path: "app/models/job.rb" },
    resultBody: "app/models/job.rb:142:  def approve!(via:, by_user:)"
  },
  {
    id: "grep_no_matches",
    label: "No matches",
    input: { pattern: "def totally_nonexistent_method" },
    resultBody: "No matches found"
  }
]

const WEB_SEARCH_EXAMPLES: ToolPresentationExample[] = [
  {
    id: "web_search_results",
    label: "Search results",
    input: { query: "Rails 8.1 Solid Queue recurring jobs" },
    resultBody:
      "1. Active Job Basics — Rails Guides\n   https://guides.rubyonrails.org/active_job_basics.html\n2. Solid Queue — GitHub\n   https://github.com/rails/solid_queue"
  },
  {
    id: "web_search_no_results",
    label: "No results",
    input: { query: "asdkjfhaslkdjfh nonsense query" },
    resultBody: "No results found."
  }
]

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
  builtin("Bash", { aliases: ["bash", "command_execution"], readOnly: false, examples: BASH_EXAMPLES }),
  builtin("Read", { readOnly: true, examples: READ_EXAMPLES }),
  builtin("Edit", { readOnly: false }),
  builtin("MultiEdit", { readOnly: false }),
  builtin("Write", { readOnly: false }),
  builtin("NotebookEdit", { readOnly: false }),
  builtin("Glob", { readOnly: true }),
  builtin("Grep", { readOnly: true, examples: GREP_EXAMPLES }),
  builtin("WebFetch", { readOnly: true }),
  builtin("WebSearch", { readOnly: true, examples: WEB_SEARCH_EXAMPLES }),
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
const LOCAL_MODE_TOOL_NAMES = new Set(["open_in_local_mode", "cancel_local_mode", "reset_workspace", "complete_implement_step", "submit_coding_changes"])

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
    examples: [
      {
        id: "job_proposal_pending",
        label: "Pending Job proposal",
        description:
          "Chat proposal cards render from the message's own `item.proposal` shape, not a tool_use/tool_result pair -- this fixture approximates that shape for catalog review rather than a real tool call.",
        parsedResult: { slug: "add-fixture-examples", kind: "job", title: "Add example fixtures for core and plugin tool presentations", state: "pending" }
      }
    ]
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
    examples: [
      {
        id: "pending_confirm_submit_coding_changes",
        label: "Pending confirmation: submit coding changes",
        description:
          "Chat pending-action cards render from the message's own `item.pending_action` shape, not a tool_use/tool_result pair -- this fixture approximates that shape for catalog review rather than a real tool call.",
        parsedResult: { action: "submit_coding_changes", status: "awaiting_confirmation" }
      }
    ]
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
// was ever registered for it (reset_workspace is explicitly cardless — see
// Admin::McpToolCardCoverage::EXPLICIT_CARD_STATUSES on the backend), so this
// runs as its own pass rather than as an inline branch inside
// mcpToolEntryFor, which only ever sees names a renderer was discovered for.
function withLocalModeOverrides(entries: ToolPresentationEntry[]): ToolPresentationEntry[] {
  const byToolName = new Map(entries.map((entry) => [entry.toolName, entry]))
  const overridden = entries.map((entry) => (LOCAL_MODE_TOOL_NAMES.has(entry.toolName) ? { ...entry, sourceType: "local_mode_tool" as const } : entry))

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
