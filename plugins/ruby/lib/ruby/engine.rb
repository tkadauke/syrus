require "rails"

module Ruby
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up interface modules now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Ruby::SimpleCovAnalyzer.include(Syrus::Plugin::CoverageAnalyzer)
      Ruby::GraderAugmentor.include(Syrus::Plugin::GraderAugmentor)
      Ruby::PrepareDetector.include(Syrus::Plugin::PrepareDetector)

      Syrus::PluginRegistry.register(
        name:             "ruby",
        version:          Ruby::VERSION,
        description:      "Ruby-generic intelligence: RSpec grader detail, SimpleCov analysis, Gemfile prepare detection",
        homepage:         "https://github.com/tkadauke/syrus",
        prepare_priority: 10,
        provides: {
          coverage_analyzer: Ruby::SimpleCovAnalyzer,
          grader_augmentor:  Ruby::GraderAugmentor,
          prepare_detector:  Ruby::PrepareDetector
        }
      )
    end
  end
end
