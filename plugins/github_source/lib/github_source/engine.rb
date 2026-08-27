module SyrusGithubSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "github_source",
        display_name:    "GitHub Source",
        version:         SyrusGithubSource::VERSION,
        description:     "Ingests GitHub issues and provides GitHub PR operations.",
        long_description: "GitHub Source is Syrus' built-in GitHub integration. It polls issues and pull requests, opens and updates PRs, reads check state, performs landing operations, and supplies the source-control primitives other workflows rely on.\n\nFor most Syrus installations this is core infrastructure and is not disableable. Future source plugins can follow the same extension points, but GitHub remains the default path for issue-to-PR automation.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/github_source.svg",
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
