module SyrusGithubSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "github_source",
        display_name:    "GitHub Source",
        version:         SyrusGithubSource::VERSION,
        description:     "Ingests GitHub issues and provides GitHub PR operations.",
        long_description: "GitHub Source is Syrus' built-in GitHub integration. It polls issues and pull requests, opens and updates PRs, reads check state, performs landing operations, and supplies the source-control primitives other workflows rely on.\n\nFor most Syrus installations this is the default path for issue-to-PR automation, so it is enabled out of the box. It can be disabled once nothing depends on it: the disable guard blocks the attempt while any input source or active repository still uses it. Future source plugins can follow the same extension points.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/github_source.svg",
        author:          "Thomas Kadauke",
        default_enabled: true,
        disableable:     true,
        category:        "input_source",
        provides: {
          input_source:            InputSources::Github,
          source_control_provider: SourceControl::GithubOperations
        }
      )
    end
  end
end
