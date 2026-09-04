module Whiteboard
  # :workspace_tab provider for the chat sidebar's Whiteboard::Board tab (see
  # Syrus::Plugin::WorkspaceTab / config/syrus_docs/plugins.md). Available in
  # every chat, matching the tab's previous unconditional, hardcoded presence
  # in app/frontend/routes/chat/workspaceTabs.ts before this migration.
  class WorkspaceTabs
    def self.workspace_tabs
      [
        {
          id: "whiteboard.canvas",
          label: "Whiteboard::Board",
          label_key: "whiteboard:tab_whiteboard",
          component: "whiteboard/WhiteboardTab",
          order: 0
        }
      ]
    end

    def self.available_for?(_chat_session)
      true
    end
  end
end
