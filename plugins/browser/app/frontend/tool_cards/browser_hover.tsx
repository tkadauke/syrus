import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserHoverToolCard: ToolCardRenderer = {
  toolName: "browser_hover",
  ...browserCardRenderer("hover")
}

export default browserHoverToolCard
