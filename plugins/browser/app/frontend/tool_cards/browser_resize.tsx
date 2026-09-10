import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserResizeToolCard: ToolCardRenderer = {
  toolName: "browser_resize",
  ...browserCardRenderer("resize")
}

export default browserResizeToolCard
