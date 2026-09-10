import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserCloseToolCard: ToolCardRenderer = {
  toolName: "browser_close",
  ...browserCardRenderer("close")
}

export default browserCloseToolCard
