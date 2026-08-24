import type { PluginWorkspaceTabProps } from "@app/pluginWorkspaceTabs"
import { useT } from "@app/hooks/useT"

// Trivial proof-of-concept tab for the :workspace_tab plugin extension point
// (see SyrusDev::WorkspaceTabs / config/syrus_docs/plugins.md). Renders in
// any chat attached to a repository, proving the full path from backend
// registration through to a lazily-loaded plugin frontend component.
export default function WorkspaceTabDemo({ payload }: PluginWorkspaceTabProps) {
  const { t } = useT("syrus_dev")

  return (
    <div className="space-y-2 text-sm text-gray-700 dark:text-gray-300">
      <p className="font-medium text-gray-900 dark:text-gray-100">{t("workspace_tab_demo_label")}</p>
      <p>{t("workspace_tab_demo_body", { chat: payload.chat.title })}</p>
    </div>
  )
}
