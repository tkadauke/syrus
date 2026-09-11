import type { ToolCardRenderer } from "@app/pluginToolCards"
import { browserCardRenderer } from "../browserToolCard"

const browserFileUploadToolCard: ToolCardRenderer = {
  toolName: "browser_file_upload",
  ...browserCardRenderer("file_upload")
}

export default browserFileUploadToolCard
