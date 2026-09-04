module TeamDirectory
  extend Syrus::PluginApi

  syrus_plugin "team_directory" do
    display_name "Team Directory"
    description "Operator directory with per-person profile pages showing recent jobs, epics, and repositories."
    long_description "Team Directory lists the people using this Syrus instance and gives each one a profile page summarising their recent jobs, epics, and repositories.\n\nIt is a read-only view over existing records and is unrelated to team-based authorization, which is core and stays in place whether or not this plugin is enabled. On a single-operator instance the sidebar entry hides itself."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/team_directory.svg"
    author "Thomas Kadauke"
    category "collaboration"
    default_enabled true
    disableable true
    provides sidebar_page: "TeamDirectory::SidebarPages"
    route :get, "/api/v1/app/profiles", to: "api/v1/app/profiles#index"
    route :get, "/api/v1/app/profiles/:id", to: "api/v1/app/profiles#show"
    frontend routes: {
          "team_directory/TeamDirectory" => "app/frontend/routes/TeamDirectory.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/team_directory.json" ]
  end
end
