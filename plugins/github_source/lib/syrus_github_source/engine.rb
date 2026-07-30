module SyrusGithubSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name: "syrus-github-source",
        version: SyrusGithubSource::VERSION,
        provides: { input_source: InputSources::Github }
      )
    end
  end
end
