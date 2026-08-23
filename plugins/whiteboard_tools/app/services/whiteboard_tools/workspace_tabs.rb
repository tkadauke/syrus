module WhiteboardTools
  # :workspace_tab provider for the chat sidebar's Whiteboard tab (see
  # Syrus::Plugin::WorkspaceTab / config/syrus_docs/plugins.md). Available in
  # every chat, matching the tab's previous unconditional, hardcoded presence
  # in app/frontend/routes/chat/workspaceTabs.ts before this migration.
  class WorkspaceTabs
    def self.workspace_tabs
      [
        {
          id: "whiteboard_tools.canvas",
          label: "Whiteboard",
          label_key: "whiteboard_tools:tab_whiteboard",
          component: "whiteboard_tools/WhiteboardTab",
          order: 0
        }
      ]
    end

    def self.available_for?(_chat_session)
      true
    end
  end
end
