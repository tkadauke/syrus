module SyrusLinearSource
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name: "syrus-linear-source",
        version: SyrusLinearSource::VERSION,
        provides: { input_source: InputSources::Linear }
      )
    end
  end
end
