
module Terminal
  extend Syrus::PluginApi

  syrus_plugin "terminal" do
    display_name "Terminal"
    category     "tooling"
    author       "Thomas Kadauke"
    icon_url     "/plugin-icons/terminal.svg"

    # Off by default: a terminal session is a shell on the worker, and the
    # security boundary is the per-session token exchanged over the relay
    # socket, not network isolation.
    default_enabled false

    description "Interactive shell sessions against a running workflow's workspace, streamed to the browser."
    long_description "Terminal opens a real PTY on the worker that owns a workflow's workspace and streams it to the browser over an authenticated Action Cable channel. Sessions survive browser navigation because the PTY lives in the worker-side session until it exits or is killed.\n\nIt is off by default and is a genuine shell: enable it only where operators are trusted with the worker filesystem. Sessions do not survive a worker restart or deploy, and there is no idle timeout."

    provides sidebar_page: "Terminal::SidebarPages",
             ui_slot:      "Terminal::UiSlots"

    route :get,    "/api/v1/app/terminal_sessions", to: "api/v1/app/terminal_sessions#index"
    route :post,   "/api/v1/app/terminal_sessions", to: "api/v1/app/terminal_sessions#create"
    route :get,    "/api/v1/app/terminal_sessions/open_count", to: "api/v1/app/terminal_sessions#open_count"
    route :get,    "/api/v1/app/terminal_sessions/:id", to: "api/v1/app/terminal_sessions#show"
    route :delete, "/api/v1/app/terminal_sessions/:id", to: "api/v1/app/terminal_sessions#destroy"
    route :post,   "/api/v1/app/terminal_sessions/:id/kill", to: "api/v1/app/terminal_sessions#kill"

    frontend routes:   { "terminal/Terminal" => "app/frontend/routes/Terminal.tsx" },
             ui_slots: { "terminal/OpenWorkspaceButton" => "app/frontend/ui_slots/OpenWorkspaceButton.tsx" }

    always do |scope|
      Terminal::DataCleanup.install_into(scope)
    end
  end
end
