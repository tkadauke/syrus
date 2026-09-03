require "team_directory/version"
require "team_directory/engine"

module TeamDirectory
  def self.register!
    Syrus::PluginRegistry.register(
      name:            "team_directory",
      display_name:    "Team Directory",
      version:         TeamDirectory::VERSION,
      default_enabled: true,
      disableable:     true,
      category:        "tooling",
      description:     "Operator directory with per-person profile pages showing recent jobs, epics, and repositories.",
      long_description: "Team Directory lists the people using this Syrus instance and gives each one a profile page summarising their recent jobs, epics, and repositories.\n\nIt is a read-only view over existing records and is unrelated to team-based authorization, which is core and stays in place whether or not this plugin is enabled. On a single-operator instance the sidebar entry hides itself.",
      homepage:        "https://github.com/tkadauke/syrus",
      icon_url:        "/plugin-icons/spqr_eagle.svg",
      author:          "Thomas Kadauke",
      frontend: {
        routes: {
          "team_directory/TeamDirectory" => "app/frontend/routes/TeamDirectory.tsx"
        },
        i18n: [ "app/frontend/i18n/locales/*/team_directory.json" ]
      },
      routes: [
        { verb: "GET", path: "/api/v1/app/profiles",     controller: "api/v1/app/profiles#index" },
        { verb: "GET", path: "/api/v1/app/profiles/:id", controller: "api/v1/app/profiles#show" }
      ],
      provides: {
        sidebar_page: TeamDirectory::SidebarPages
      }
    )
  end

  def self.enabled?
    Syrus::PluginRegistry.all_plugins.any? { |manifest| manifest.name == "team_directory" && manifest.enabled? }
  end
end
