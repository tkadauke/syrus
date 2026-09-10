import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserDropToolCard: ToolCardRenderer = {
  toolName: "browser_drop",
  ...browserCardRenderer("drop")
}

export default browserDropToolCard
