import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserClickToolCard: ToolCardRenderer = {
  toolName: "browser_click",
  ...browserCardRenderer("click")
}

export default browserClickToolCard

// Reviewable sample payload for the Tool Card Catalog (a later Job) — see
// pluginToolCards.tsx's ToolCardExample. Plugin-owned, same as the card
// itself, so the catalog never needs a core edit to pick this up.
export const examples = [
  {
    label: "Click a submit button",
    input: { target: "submit-button", element: "Submit button" },
    resultBody: JSON.stringify({ clicked: true })
  }
]
