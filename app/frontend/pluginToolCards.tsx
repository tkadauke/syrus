import type { ReactNode } from "react"

// Extension point for custom chat tool-call cards (EPIC-291 / JOB-4219).
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
  // and the row itself stays collapsed by default (JOB-4072).
  renderExpanded: (context: ToolCardContext) => ReactNode | null
}

// Small guard card authors can reuse to defend against a malformed or
// unexpected parsedResult shape instead of hand-rolling their own check.
export function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

type ToolCardModule = { default?: ToolCardRenderer }

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

const registeredToolCardRenderers: ToolCardRenderer[] = Object.entries(cardModules).flatMap(([path, mod]) => {
  const renderer = mod.default
  if (!isValidRenderer(renderer)) {
    console.warn(`[pluginToolCards] Skipping ${path}: default export is not a valid ToolCardRenderer`)
    return []
  }

  return [renderer]
})

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
