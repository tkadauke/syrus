import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserClickToolCard: ToolCardRenderer = {
  toolName: "browser_click",
  ...browserCardRenderer("click")
}

export default browserClickToolCard
