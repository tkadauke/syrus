module SyrusLinearSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "linear_source",
        display_name:    "Linear Source",
        version:         SyrusLinearSource::VERSION,
        description:     "Ingests Linear issues as Syrus jobs and epics.",
        long_description: "Linear Source connects Syrus to Linear teams and issues. It lets operators ingest Linear work into Syrus jobs and epics while preserving Linear as the planning system of record.\n\nThe plugin is disabled by default because it requires Linear credentials and team selection. It complements GitHub Source: Linear can provide the work intake while GitHub remains the code and PR backend.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/linear_source.svg",
        author:          "Thomas Kadauke",
        default_enabled: false,
        disableable:     true,
        category:        "input_source",
        routes: [
          {
            verb: "GET",
            path: "/api/v1/app/linear/teams",
            controller: "api/v1/app/linear#teams"
          }
        ],
        provides: { input_source: InputSources::Linear }
      )
    end
  end
end
