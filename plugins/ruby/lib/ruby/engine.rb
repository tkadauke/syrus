require "rails"

module Ruby
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up interface modules now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Ruby::SimpleCovAnalyzer.include(Syrus::Plugin::CoverageAnalyzer)
      Ruby::GraderAugmentor.include(Syrus::Plugin::GraderAugmentor)
      Ruby::RubocopGraderAugmentor.include(Syrus::Plugin::GraderAugmentor)
      Ruby::PrepareDetector.include(Syrus::Plugin::PrepareDetector)
      Ruby::ReviewCriteriaProvider.include(Syrus::Plugin::ReviewCriteriaProvider)
      Ruby::RspecParser.include(Syrus::Plugin::TestResultParser)
      Ruby::RubocopAutofix.include(Syrus::Plugin::AutofixCommand)
      Ruby::BundlerAuditCommand.include(Syrus::Plugin::DependencyAuditCommand)

      Syrus::PluginRegistry.register(
        name:             "ruby",
        version:          Ruby::VERSION,
        description:      "Ruby-generic intelligence: RSpec grader detail, RuboCop grader detail, " \
                           "RSpec output parsing, SimpleCov analysis, Gemfile prepare detection, " \
                           "RuboCop autofix, bundler-audit dependency scanning, default N+1 review criterion",
        homepage:         "https://github.com/tkadauke/syrus",
        prepare_priority: 10,
        provides: {
          coverage_analyzer:        Ruby::SimpleCovAnalyzer,
          grader_augmentor:         [ Ruby::GraderAugmentor, Ruby::RubocopGraderAugmentor ],
          prepare_detector:         Ruby::PrepareDetector,
          review_criteria_provider: Ruby::ReviewCriteriaProvider,
          test_result_parser:       Ruby::RspecParser,
          autofix_command:          Ruby::RubocopAutofix,
          dependency_audit_command: Ruby::BundlerAuditCommand
        }
      )
    end
  end
end
