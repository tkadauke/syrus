module Whiteboard
  extend Syrus::PluginApi

  syrus_plugin "whiteboard" do
    display_name "Whiteboard::Board"
    description "Excalidraw-based chat whiteboard: workspace sidebar tab plus draw/move/delete/read/" \
      "save/clear/load MCP tools so agents and operators can sketch together on a shared " \
      "per-chat canvas."
    long_description "Whiteboard::Board adds a shared Excalidraw canvas to chat workspaces and exposes drawing tools to chat agents. Operators and agents can sketch flows, annotate ideas, save snapshots, and revisit visual state as part of a planning session.\n\nUse it for design and architecture discussions where text is not enough. The plugin stores whiteboard state per chat and keeps the drawing surface separate from repository code."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/whiteboard.svg"
    author "Thomas Kadauke"
    category "agent_capability"
    default_enabled true
    disableable true
    provides chat_mcp_tool_set: "Whiteboard::ChatToolSet",
             workspace_tab: "Whiteboard::WorkspaceTabs",
             chat_media_source: "Whiteboard::MediaSource",
             chat_payload_contributor: "Whiteboard::PayloadContributor",
             chat_prompt_injector: "Whiteboard::PromptSection"
    route :get, "/api/v1/app/chats/:id/whiteboard", to: "api/v1/app/chat_whiteboards#show"
    route :patch, "/api/v1/app/chats/:id/whiteboard", to: "api/v1/app/chat_whiteboards#update"
    route :get, "/api/v1/app/chats/:chat_id/whiteboard_snapshots", to: "api/v1/app/whiteboard_snapshots#index"
    route :post, "/api/v1/app/chats/:chat_id/whiteboard_snapshots", to: "api/v1/app/whiteboard_snapshots#create"
    route :get, "/api/v1/app/chats/:chat_id/whiteboard_snapshots/:id", to: "api/v1/app/whiteboard_snapshots#show"
    frontend workspace_tabs: {
          "whiteboard/WhiteboardTab" => "app/frontend/workspaceTabs/WhiteboardTab.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/whiteboard.json" ]

    always do |scope|
      Whiteboard::DataCleanup.install_into(scope)
    end
  end
end
