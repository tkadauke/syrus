import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserPressKeyToolCard: ToolCardRenderer = {
  toolName: "browser_press_key",
  ...browserCardRenderer("press_key")
}

export default browserPressKeyToolCard
