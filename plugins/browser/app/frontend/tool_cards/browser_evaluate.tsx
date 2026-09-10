import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserEvaluateToolCard: ToolCardRenderer = {
  toolName: "browser_evaluate",
  ...browserCardRenderer("evaluate")
}

export default browserEvaluateToolCard
