module ReviewWorkspacePlugin
  extend Syrus::Host::PluginApi

  syrus_plugin "review_workspace" do
    display_name "Review Workspace"
    category "collaboration"
    author "Thomas Kadauke"
    icon_url "/plugin-icons/review_workspace.svg"
    description "A focused stack of Jobs on which the signed-in operator can act now."
    long_description "Review Workspace adds a top-level Review destination containing only implemented, non-investigation Jobs the signed-in operator can currently approve. The badge and workspace share the same eligibility query, and no read, unread, or deferred state is stored."
    default_enabled true
    disableable true

    link "Open Review", "/review", description: "Review Jobs that can receive your decision now."
    provides sidebar_pages: "ReviewWorkspacePlugin::SidebarPages",
             ui_slots: "ReviewWorkspacePlugin::UiSlots"

    route :get, "/api/v1/app/review_workspace", to: "api/v1/app/review_workspace#index"
    route :get, "/api/v1/app/review_workspace/count", to: "api/v1/app/review_workspace#count"

    frontend routes: { "review_workspace/ReviewWorkspace" => "app/frontend/routes/ReviewWorkspace.tsx" },
             ui_slots: { "review_workspace/ReviewDashboardNotice" => "app/frontend/ui_slots/ReviewDashboardNotice.tsx" },
             i18n: [ "app/frontend/i18n/locales/*/review_workspace.json" ]
  end
end
