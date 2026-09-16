import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserClickToolCard: ToolCardRenderer = {
  toolName: "browser_click",
  ...browserCardRenderer("click")
}

export default browserClickToolCard

// Reviewable sample payloads for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample. Plugin-owned, same as the card
// itself, so the catalog never needs a core edit to pick this up.
export const examples = [
  {
    id: "click_submit_button",
    label: "Click a submit button",
    input: { target: "submit-button", element: "Submit button" },
    parsedResult: { clicked: true }
  },
  {
    id: "click_target_not_found",
    label: "Error: target not found",
    description: "The MCP tool call failed (result_error true) -- demonstrates the shared browser-tool error presentation.",
    input: { target: "stale-ref-42", element: "Submit button" },
    resultError: true,
    parsedResult: { error: 'Element not found for target "stale-ref-42". Call browser_snapshot again to get a fresh target.' }
  }
]
