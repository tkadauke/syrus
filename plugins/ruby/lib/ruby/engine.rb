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
      Ruby::AffectedTestAnalyzer.include(Syrus::Plugin::AffectedTestAnalyzer)

      Syrus::PluginRegistry.register(
        name:             "ruby",
        version:          Ruby::VERSION,
        description:      "Ruby-generic intelligence: RSpec grader detail, RuboCop grader detail, " \
                           "RSpec output parsing, SimpleCov analysis, Gemfile prepare detection, " \
                           "RuboCop autofix, bundler-audit dependency scanning, default N+1 review criterion, " \
                           "require_relative-graph affected-test analysis",
        long_description: "Ruby provides language-level support for Ruby repositories independent of Rails. It detects Gemfile-based projects, prepares Bundler dependencies, augments RSpec and RuboCop output, parses RSpec JSON/JUnit results, analyzes SimpleCov coverage, and supplies common Ruby autofix and dependency-audit commands.\n\nUse it for gems, scripts, services, Sinatra apps, and any mixed repository with Ruby code. Rails-specific capabilities live in the Syrus Rails plugin so core Ruby support stays broadly applicable.",
        homepage:         "https://github.com/tkadauke/syrus",
        author:           "Thomas Kadauke",
        icon_url:         "/plugin-icons/ruby.svg",
        category:         "language",
        prepare_priority: 10,
        provides: {
          coverage_analyzer:        Ruby::SimpleCovAnalyzer,
          grader_augmentor:         [ Ruby::GraderAugmentor, Ruby::RubocopGraderAugmentor ],
          prepare_detector:         Ruby::PrepareDetector,
          review_criteria_provider: Ruby::ReviewCriteriaProvider,
          test_result_parser:       Ruby::RspecParser,
          autofix_command:          Ruby::RubocopAutofix,
          dependency_audit_command: Ruby::BundlerAuditCommand,
          affected_test_analyzer:   Ruby::AffectedTestAnalyzer
        }
      )
    end
  end
end
