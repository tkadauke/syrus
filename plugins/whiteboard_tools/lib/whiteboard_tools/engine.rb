module WhiteboardTools
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) and app/services/whiteboard_tools
    # (autoloaded from this engine's own app/ dir) are resolvable.
    config.after_initialize do
      WhiteboardTools::ChatToolSet.include(Syrus::Plugin::ChatMcpToolSet) unless WhiteboardTools::ChatToolSet < Syrus::Plugin::ChatMcpToolSet
      WhiteboardTools::WorkspaceTabs.include(Syrus::Plugin::WorkspaceTab) unless WhiteboardTools::WorkspaceTabs < Syrus::Plugin::WorkspaceTab

      Syrus::PluginRegistry.register(
        name:            "whiteboard_tools",
        display_name:    "Whiteboard",
        version:         WhiteboardTools::VERSION,
        description:     "Excalidraw-based chat whiteboard: workspace sidebar tab plus draw/move/delete/read/" \
                          "save/clear/load MCP tools so agents and operators can sketch together on a shared " \
                          "per-chat canvas.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "workspace_tab",
        frontend: {
          workspace_tabs: {
            "whiteboard_tools/WhiteboardTab" => "app/frontend/workspaceTabs/WhiteboardTab.tsx"
          },
          i18n: [ "app/frontend/i18n/locales/*/whiteboard_tools.json" ]
        },
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/chats/:id/whiteboard",
            controller: "api/v1/app/chat_whiteboards#show"
          },
          {
            verb: "PATCH",
            path: "/api/v1/app/chats/:id/whiteboard",
            controller: "api/v1/app/chat_whiteboards#update"
          },
          {
            verb: "GET",
            path: "/api/v1/app/chats/:chat_id/whiteboard_snapshots",
            controller: "api/v1/app/whiteboard_snapshots#index"
          },
          {
            verb: "POST",
            path: "/api/v1/app/chats/:chat_id/whiteboard_snapshots",
            controller: "api/v1/app/whiteboard_snapshots#create"
          },
          {
            verb: "GET",
            path: "/api/v1/app/chats/:chat_id/whiteboard_snapshots/:id",
            controller: "api/v1/app/whiteboard_snapshots#show"
          }
        ],
        provides: {
          chat_mcp_tool_set: WhiteboardTools::ChatToolSet,
          workspace_tab:     WhiteboardTools::WorkspaceTabs
        }
      )
    end
  end
end
