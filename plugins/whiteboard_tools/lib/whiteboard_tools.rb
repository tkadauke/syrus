module WhiteboardTools
  extend Syrus::PluginApi

  syrus_plugin "whiteboard_tools" do
    display_name "WhiteboardTools::Board"
    description "Excalidraw-based chat whiteboard: workspace sidebar tab plus draw/move/delete/read/" \
      "save/clear/load MCP tools so agents and operators can sketch together on a shared " \
      "per-chat canvas."
    long_description "WhiteboardTools::Board adds a shared Excalidraw canvas to chat workspaces and exposes drawing tools to chat agents. Operators and agents can sketch flows, annotate ideas, save snapshots, and revisit visual state as part of a planning session.\n\nUse it for design and architecture discussions where text is not enough. The plugin stores whiteboard state per chat and keeps the drawing surface separate from repository code."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/whiteboard_tools.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled true
    disableable true
    provides chat_mcp_tool_set: "WhiteboardTools::ChatToolSet",
             workspace_tab: "WhiteboardTools::WorkspaceTabs",
             chat_media_source: "WhiteboardTools::MediaSource",
             chat_payload_contributor: "WhiteboardTools::PayloadContributor",
             chat_prompt_injector: "WhiteboardTools::PromptSection"
    route :get, "/api/v1/app/chats/:id/whiteboard", to: "api/v1/app/chat_whiteboards#show"
    route :patch, "/api/v1/app/chats/:id/whiteboard", to: "api/v1/app/chat_whiteboards#update"
    route :get, "/api/v1/app/chats/:chat_id/whiteboard_snapshots", to: "api/v1/app/whiteboard_snapshots#index"
    route :post, "/api/v1/app/chats/:chat_id/whiteboard_snapshots", to: "api/v1/app/whiteboard_snapshots#create"
    route :get, "/api/v1/app/chats/:chat_id/whiteboard_snapshots/:id", to: "api/v1/app/whiteboard_snapshots#show"
    frontend workspace_tabs: {
          "whiteboard_tools/WhiteboardTab" => "app/frontend/workspaceTabs/WhiteboardTab.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/whiteboard_tools.json" ]

    always do |scope|
      WhiteboardTools::DataCleanup.install_into(scope)
    end
  end
end
