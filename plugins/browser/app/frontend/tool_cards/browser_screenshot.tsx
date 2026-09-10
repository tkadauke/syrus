import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserScreenshotToolCard: ToolCardRenderer = {
  toolName: "browser_screenshot",
  ...browserCardRenderer("screenshot")
}

export default browserScreenshotToolCard
