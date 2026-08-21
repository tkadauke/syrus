require "rails"

module Go
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up the interface module now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Go::PrepareDetector.include(Syrus::Plugin::PrepareDetector)
      Go::ReviewCriteriaProvider.include(Syrus::Plugin::ReviewCriteriaProvider)

      Syrus::PluginRegistry.register(
        name:             "go",
        version:          Go::VERSION,
        description:      "Go prepare detection: go.mod → go mod download; default swallowed-error review criterion",
        homepage:         "https://github.com/tkadauke/syrus",
        prepare_priority: 40,
        provides: {
          prepare_detector:         Go::PrepareDetector,
          review_criteria_provider: Go::ReviewCriteriaProvider
        }
      )
    end
  end
end
