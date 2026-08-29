import type { PluginWorkspaceTabProps } from "@app/pluginWorkspaceTabs"
import { DesignDocsSurface } from "../components/DesignDocsSurface"

export default function WorkspaceDesignDocs({ payload }: PluginWorkspaceTabProps) {
  return (
    <div className="h-full overflow-y-auto p-4">
      <DesignDocsSurface chatId={payload.chat.id} compact mode="chat" repositoryId={payload.chat.repository?.id} />
    </div>
  )
}
