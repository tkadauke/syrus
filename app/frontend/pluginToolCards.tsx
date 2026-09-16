import type { ReactNode } from "react"
export { isPlainObject } from "./toolCardParsing"

// Extension point for custom chat tool-call cards (the Tier 1 tool-card work).
//
// A "tool card" upgrades how one MCP tool's call renders inside a chat
// ToolGroup (see routes/chat/MessageCards.tsx) and the admin transcript
// viewer (see routes/AdminTranscript.tsx), which share the same rendering
// path. Plugin-defined MCP tools register their card next to the tool
// definition, under `<plugin>/app/frontend/tool_cards/*.tsx` — this file
// discovers them by directory convention (mirrors pluginUiSlots.tsx), so
// adding a new plugin card never requires editing this file or any other
// core file. Core-owned tools may register their own cards the same way,
// under `routes/chat/tool_cards/*.tsx`.
//
// A tool with no registered card (unknown to core and to every installed
// plugin) keeps rendering through the generic highlighted-JSON/text body.
export type ToolCardContext = {
  // Normalized tool name, e.g. "list_design_docs" (mcp__ prefixes and
  // sidecar server prefixes already stripped — see toolRendering.ts).
  toolName: string
  // Tool call arguments. Only populated where the caller already has them
  // (the expanded chat card); collapsed-summary dispatch does not carry it.
  input?: Record<string, unknown>
  // Raw tool result text, before any JSON parsing.
  resultBody: string
  resultError: boolean
  // Best-effort JSON.parse of resultBody; null when it isn't JSON.
  parsedResult: unknown
}

export type ToolCardRenderer = {
  toolName: string
  // One-line summary shown in the collapsed row. Return null/undefined
  // (or omit this) to keep the generic count/text summary.
  collapsedSummary?: (context: ToolCardContext) => string | null | undefined
  // Friendly expanded view shown when the call is opened. Return null for
  // a malformed/unexpected payload so the generic body renders instead;
  // the raw JSON "Raw details" disclosure always stays available
  // regardless of which body renders (see MessageCards.tsx ToolGroup),
  // and the row itself stays collapsed by default .
  renderExpanded: (context: ToolCardContext) => ReactNode | null
}

// Which provider's raw result shape a fixture simulates. Both providers
// ultimately normalize into the same ToolCardContext (see
// toolCardContextForExample below), so this is mostly documentation for a
// human reviewer -- but it matters for provider-builtin entries with no MCP
// envelope at all (Bash/Read/Grep/...), where Claude and Codex genuinely
// produce differently-shaped raw content (Claude wraps tool_result content in
// `[{type:"text", text}]` blocks; Codex's command_execution/function_call
// items carry plain output text or a raw object directly -- see
// plugins/codex_agent/app/services/codex_agent/transcript_events.rb).
// "generic" is for fixtures that aren't demonstrating a provider-specific
// shape at all (most MCP tool card examples).
export type ToolCardExampleSourceType = "claude" | "codex" | "generic"

// A named, reviewable sample payload for a card — the Tool Card Catalog (a
// later Job) renders these so an operator can see every presentation without
// digging up a real transcript. A card module opts in by exporting a named
// `examples` array next to its default renderer; this stays entirely
// optional and additive, so existing cards with no `examples` export keep
// working unchanged (see discoveredToolCardEntries below, which defaults to
// an empty array).
export type ToolCardExample = {
  // Stable identifier within this tool's example set -- a React key and a
  // future catalog deep-link target, so it must survive reordering the
  // `examples` array. Convention: lower_snake_case, e.g. "two_open_jobs".
  id: string
  label: string
  // Longer note for a human reviewer on what this fixture demonstrates or
  // why it's shaped the way it is (e.g. "malformed: missing required
  // `job` key"). Omit when the label already says it all.
  description?: string
  input?: Record<string, unknown>
  // Provide exactly one of resultBody/parsedResult. resultBody is the raw
  // result text a real tool_result would carry (already JSON-encoded where
  // relevant); parsedResult is a convenience for authors who'd rather write
  // a plain JS value than hand-encode JSON -- toolCardContextForExample
  // derives resultBody from it via JSON.stringify. Supplying resultBody
  // directly is required for non-JSON (or deliberately malformed-JSON)
  // fixtures, since those can't round-trip through a parsed value.
  resultBody?: string
  parsedResult?: unknown
  resultError?: boolean
  sourceType?: ToolCardExampleSourceType
}

type ToolCardModule = { default?: ToolCardRenderer; examples?: ToolCardExample[] }

// Resolves the effective result text for an example: resultBody wins when
// both are given (it's the more literal, authoritative source); otherwise a
// supplied parsedResult is JSON-encoded; with neither, the empty string
// (the "no result body" / empty fixture case).
export function resolveExampleResultBody(example: ToolCardExample): string {
  if (example.resultBody !== undefined) return example.resultBody
  if (example.parsedResult !== undefined) return JSON.stringify(example.parsedResult)
  return ""
}

function bestEffortJsonParse(body: string): unknown {
  if (!body) return null
  try {
    return JSON.parse(body)
  } catch {
    return null
  }
}

// Builds a real ToolCardContext from an example fixture, the same shape a
// live transcript produces (see ToolCardContext above) -- so a catalog page
// can feed a fixture straight into renderToolCard/summarizeToolCard without
// its own normalization pass. parsedResult prefers the example's own
// (possibly non-JSON-derived) value when given, otherwise best-effort
// JSON.parses the resolved resultBody exactly like a live tool_result would
// (see ToolCardContext.parsedResult's contract) -- so a "malformed" fixture
// (resultBody: "not json") correctly yields parsedResult: null and exercises
// a card's fallback path instead of throwing.
export function toolCardContextForExample(toolName: string, example: ToolCardExample): ToolCardContext {
  const resultBody = resolveExampleResultBody(example)
  return {
    toolName,
    input: example.input,
    resultBody,
    resultError: example.resultError ?? false,
    parsedResult: example.parsedResult !== undefined ? example.parsedResult : bestEffortJsonParse(resultBody)
  }
}

// Owner attribution for a discovered card, derived from its directory
// convention alone (see PLUGIN_CARD_PATH_PATTERN below) — never from a
// hand-maintained list, so a new plugin's cards are correctly attributed
// without touching this file. Consumed by toolPresentationRegistry.ts,
// which needs to know whether a discovered card belongs to core or to a
// specific plugin without re-globbing the filesystem itself.
export type ToolCardOwner = { ownerType: "core" | "plugin"; ownerName: string }

export type DiscoveredToolCardEntry = { renderer: ToolCardRenderer; owner: ToolCardOwner; examples: ToolCardExample[]; path: string }

const PLUGIN_CARD_PATH_PATTERN = /\/plugins\/([^/]+)\/app\/frontend\/tool_cards\//

const cardModules = import.meta.glob<ToolCardModule>(
  [
    "../../plugins/*/app/frontend/tool_cards/*.tsx",
    "!../../plugins/*/app/frontend/tool_cards/*.test.tsx",
    "./routes/chat/tool_cards/*.tsx",
    "!./routes/chat/tool_cards/*.test.tsx"
  ],
  { eager: true }
)

function isValidRenderer(renderer: ToolCardRenderer | undefined): renderer is ToolCardRenderer {
  return !!renderer && typeof renderer.toolName === "string" && renderer.toolName.length > 0 && typeof renderer.renderExpanded === "function"
}

function ownerForCardPath(path: string): ToolCardOwner {
  const pluginMatch = path.match(PLUGIN_CARD_PATH_PATTERN)
  return pluginMatch ? { ownerType: "plugin", ownerName: pluginMatch[1] } : { ownerType: "core", ownerName: "core" }
}

export const discoveredToolCardEntries: DiscoveredToolCardEntry[] = Object.entries(cardModules).flatMap(([path, mod]) => {
  const renderer = mod.default
  if (!isValidRenderer(renderer)) {
    console.warn(`[pluginToolCards] Skipping ${path}: default export is not a valid ToolCardRenderer`)
    return []
  }

  return [{ renderer, owner: ownerForCardPath(path), examples: mod.examples ?? [], path }]
})

const registeredToolCardRenderers: ToolCardRenderer[] = discoveredToolCardEntries.map((entry) => entry.renderer)

export function pluginToolCardRendererFor(toolName: string): ToolCardRenderer | null {
  return registeredToolCardRenderers.find((renderer) => renderer.toolName === toolName) ?? null
}

export function pluginToolCardRendererKeys() {
  return registeredToolCardRenderers.map((renderer) => renderer.toolName).sort()
}

function logCardError(stage: string, toolName: string, error: unknown) {
  console.error(`[pluginToolCards] ${stage} for "${toolName}" threw`, error)
}

// Isolated from renderer lookup so both the real glob-discovered registry
// and unit tests can exercise the malformed-payload/fallback contract with
// a hand-built renderer.
export function summarizeToolCard(renderer: ToolCardRenderer | null | undefined, context: ToolCardContext): string | null {
  if (!renderer?.collapsedSummary) return null

  try {
    return renderer.collapsedSummary(context) ?? null
  } catch (error) {
    logCardError("collapsedSummary", context.toolName, error)
    return null
  }
}

export function renderToolCard(renderer: ToolCardRenderer | null | undefined, context: ToolCardContext): ReactNode | null {
  if (!renderer) return null

  try {
    return renderer.renderExpanded(context) ?? null
  } catch (error) {
    logCardError("renderExpanded", context.toolName, error)
    return null
  }
}

export function pluginToolCardCollapsedSummary(context: ToolCardContext): string | null {
  return summarizeToolCard(pluginToolCardRendererFor(context.toolName), context)
}

export function pluginToolCardExpandedBody(context: ToolCardContext): ReactNode | null {
  return renderToolCard(pluginToolCardRendererFor(context.toolName), context)
}
