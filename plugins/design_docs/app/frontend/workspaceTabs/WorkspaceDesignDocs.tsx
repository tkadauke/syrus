import type { PluginWorkspaceTabProps } from "@app/pluginWorkspaceTabs"
import type { DesignDocSummary } from "../api/designDocs"
import { DesignDocsSurface } from "../components/DesignDocsSurface"

export default function WorkspaceDesignDocs({ payload, tab }: PluginWorkspaceTabProps) {
  const designDocIds = Array.isArray(tab?.data?.design_doc_ids)
    ? tab.data.design_doc_ids.filter((id): id is number => typeof id === "number")
    : []
  const designDocId = typeof tab?.data?.design_doc_id === "number" ? tab.data.design_doc_id : designDocIds[0]
  const designDocs = Array.isArray(tab?.data?.design_docs)
    ? tab.data.design_docs.filter((doc): doc is DesignDocSummary => isDesignDocSummary(doc))
    : []

  return (
    <div className="h-full overflow-y-auto p-4">
      <DesignDocsSurface
        chatId={payload.chat.id}
        compact
        designDocIds={designDocIds}
        initialDesignDocId={designDocId}
        initialDesignDocs={designDocs}
        key={designDocId ?? "empty"}
        mode="chat"
        repositoryId={payload.chat.repository?.id}
      />
    </div>
  )
}

function isDesignDocSummary(value: unknown): value is DesignDocSummary {
  if (!value || typeof value !== "object") return false

  const doc = value as Record<string, unknown>
  return typeof doc.id === "number" && typeof doc.display_id === "string" && typeof doc.title === "string"
}
