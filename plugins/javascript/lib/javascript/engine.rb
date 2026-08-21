require "rails"

module JavaScript
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up the interface module now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      JavaScript::PrepareDetector.include(Syrus::Plugin::PrepareDetector)

      Syrus::PluginRegistry.register(
        name:             "javascript",
        version:          JavaScript::VERSION,
        description:      "Node/JS (and TS) prepare detection: yarn/pnpm/npm lockfile priority",
        homepage:         "https://github.com/tkadauke/syrus",
        prepare_priority: 20,
        provides: {
          prepare_detector: JavaScript::PrepareDetector
        }
      )
    end
  end
end
