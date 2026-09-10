import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserDragToolCard: ToolCardRenderer = {
  toolName: "browser_drag",
  ...browserCardRenderer("drag")
}

export default browserDragToolCard
