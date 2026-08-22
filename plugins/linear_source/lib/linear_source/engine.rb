module SyrusLinearSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "linear_source",
        display_name:    "Linear Source",
        version:         SyrusLinearSource::VERSION,
        description:     "Ingests Linear issues as Syrus jobs and epics.",
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
