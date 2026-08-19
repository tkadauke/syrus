module SyrusGithubSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "github_source",
        display_name:    "GitHub Source",
        version:         SyrusGithubSource::VERSION,
        description:     "Ingests GitHub issues and provides GitHub PR operations.",
        homepage:        "https://github.com/tkadauke/syrus",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     false,
        category:        "input_source",
        provides: {
          input_source:            InputSources::Github,
          source_control_provider: SourceControl::GithubOperations
        }
      )
    end
  end
end
