import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserSnapshotToolCard: ToolCardRenderer = {
  toolName: "browser_snapshot",
  ...browserCardRenderer("snapshot")
}

export default browserSnapshotToolCard
