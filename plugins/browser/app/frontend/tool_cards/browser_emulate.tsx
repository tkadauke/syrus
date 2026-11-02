import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserEmulateToolCard: ToolCardRenderer = {
  toolName: "browser_emulate",
  ...browserCardRenderer("emulate")
}

export default browserEmulateToolCard
