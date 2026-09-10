import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserWaitForToolCard: ToolCardRenderer = {
  toolName: "browser_wait_for",
  ...browserCardRenderer("wait")
}

export default browserWaitForToolCard
