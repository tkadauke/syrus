require "ruby/grader_augmentor"
require "ruby/rubocop_grader_augmentor"
require "ruby/rubocop_autofix"
require "ruby/bundler_audit_command"
require "ruby/simple_cov_analyzer"
require "ruby/prepare_detector"
require "ruby/review_criteria_provider"
require "ruby/rspec_parser"
require "ruby/affected_test_analyzer"

module Ruby
  extend Syrus::PluginApi

  syrus_plugin "ruby" do
    description "Ruby-generic intelligence: RSpec grader detail, RuboCop grader detail, " \
      "RSpec output parsing, SimpleCov analysis, Gemfile prepare detection, " \
      "RuboCop autofix, bundler-audit dependency scanning, default N+1 review criterion, " \
      "require_relative-graph affected-test analysis"
    long_description "Ruby provides language-level support for Ruby repositories independent of Rails. It detects Gemfile-based projects, prepares Bundler dependencies, augments RSpec and RuboCop output, parses RSpec JSON/JUnit results, analyzes SimpleCov coverage, and supplies common Ruby autofix and dependency-audit commands.\n\nUse it for gems, scripts, services, Sinatra apps, and any mixed repository with Ruby code. Rails-specific capabilities live in the Syrus Rails plugin so core Ruby support stays broadly applicable."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/ruby.svg"
    author "Thomas Kadauke"
    category "language"
    prepare_priority 10
    optionally_depends_on [ "test_insights" ]

    suggests_enabling "Ruby repositories get Bundler prepare, RSpec and RuboCop grader detail, SimpleCov coverage analysis, and autofix commands." do |signals|
      signals.repositories_detecting("ruby")
    end

    provides coverage_analyzer: "Ruby::SimpleCovAnalyzer",
             grader_augmentor: [ "Ruby::GraderAugmentor", "Ruby::RubocopGraderAugmentor" ],
             prepare_detector: "Ruby::PrepareDetector",
             review_criteria_provider: "Ruby::ReviewCriteriaProvider",
             "test_insights:parser" => "Ruby::RspecParser",
             autofix_command: "Ruby::RubocopAutofix",
             dependency_audit_command: "Ruby::BundlerAuditCommand",
             affected_test_analyzer: "Ruby::AffectedTestAnalyzer"
  end
end
