import type { QueryKey } from "@tanstack/react-query"
import type { ChatPreviewPanelVisibility } from "@app/api/chats"
import { PreviewPanelFrame } from "@app/routes/chat/WorkspacePanels"
import { updateMockupPanelVisibility, type MockupPanel } from "../api/mockups"

export function MockupPreviewPanel({
  panel,
  queryKey,
  onNotice,
  onPanelUpdated
}: {
  panel: MockupPanel
  queryKey: QueryKey
  onNotice: (message: string | null) => void
  onPanelUpdated: (panel: MockupPanel) => void
}) {
  return (
    <PreviewPanelFrame
      onNotice={onNotice}
      onVisibilityChange={(visibility: ChatPreviewPanelVisibility) => updateMockupPanelVisibility(panel.app_visibility_path, visibility)}
      onVisibilityUpdated={(updated) => onPanelUpdated(updated as MockupPanel)}
      panel={panel}
      queryKey={queryKey}
    />
  )
}
