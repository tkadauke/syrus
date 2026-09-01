import type { PluginWorkspaceTabProps } from "@app/pluginWorkspaceTabs"
import type { DesignDocSummary } from "../api/designDocs"
import { DesignDocsSurface } from "../components/DesignDocsSurface"

export default function WorkspaceDesignDocs({ payload, tab }: PluginWorkspaceTabProps) {
  const designDocIds = Array.isArray(tab?.data?.design_doc_ids)
    ? tab.data.design_doc_ids.filter((id): id is number => typeof id === "number")
    : []
  const selectedDesignDocId = typeof tab?.data?.selected_design_doc_id === "number"
    ? tab.data.selected_design_doc_id
    : designDocIds[0] ?? null
  const designDocs = Array.isArray(tab?.data?.design_docs)
    ? tab.data.design_docs.filter(isDesignDocSummary)
    : []

  return (
    <div className="h-full overflow-y-auto p-4">
      <DesignDocsSurface
        chatId={payload.chat.id}
        compact
        designDocIds={designDocIds}
        initialDesignDocs={designDocs}
        initialSelectedDesignDocId={selectedDesignDocId}
        key={selectedDesignDocId ?? "empty"}
        mode="chat"
        repositoryId={payload.chat.repository?.id}
      />
    </div>
  )
}

function isDesignDocSummary(value: unknown): value is DesignDocSummary {
  if (!value || typeof value !== "object") return false

  const candidate = value as Partial<DesignDocSummary>
  return (
    typeof candidate.id === "number" &&
    typeof candidate.display_id === "string" &&
    typeof candidate.title === "string"
  )
}
