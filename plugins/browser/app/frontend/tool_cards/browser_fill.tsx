import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserFillToolCard: ToolCardRenderer = {
  toolName: "browser_fill",
  ...browserCardRenderer("fill")
}

export default browserFillToolCard
