import type { PluginWorkspaceTabProps } from "@app/pluginWorkspaceTabs"
import { DesignDocsSurface } from "../components/DesignDocsSurface"

export default function WorkspaceDesignDocs({ payload, tab }: PluginWorkspaceTabProps) {
  const designDocIds = Array.isArray(tab?.data?.design_doc_ids)
    ? tab.data.design_doc_ids.filter((id): id is number => typeof id === "number")
    : []

  return (
    <div className="h-full overflow-y-auto p-4">
      <DesignDocsSurface chatId={payload.chat.id} compact designDocIds={designDocIds} mode="chat" repositoryId={payload.chat.repository?.id} />
    </div>
  )
}
