import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserNavigateToolCard: ToolCardRenderer = {
  toolName: "browser_navigate",
  ...browserCardRenderer("navigate")
}

export default browserNavigateToolCard
