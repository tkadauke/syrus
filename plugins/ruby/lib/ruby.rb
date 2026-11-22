require "ruby/grader_augmentor"
require "ruby/rubocop_grader_augmentor"
require "ruby/rubocop_autofix"
require "ruby/bundler_audit_command"
require "ruby/simple_cov_analyzer"
require "ruby/prepare_detector"
require "ruby/grade_detector"
require "ruby/rspec_grader_type"
require "ruby/minitest_grader_type"
require "ruby/review_criteria_provider"
require "ruby/rspec_parser"
require "ruby/affected_test_analyzer"
require "ruby/focused_test_command"
require "ruby/ecosystem"

module Ruby
  extend Syrus::PluginApi

  syrus_plugin "ruby" do
    description "Ruby-generic intelligence: RSpec and Minitest grader detail, RuboCop grader detail, " \
      "RSpec output parsing, SimpleCov analysis, Gemfile prepare detection, " \
      "RuboCop autofix, bundler-audit dependency scanning, default N+1 review criterion, " \
      "require_relative-graph affected-test analysis, RSpec and Minitest grade detection"
    long_description "Ruby provides language-level support for Ruby repositories independent of Rails. It detects Gemfile-based projects, prepares Bundler dependencies, augments RSpec and RuboCop output, parses RSpec JSON/JUnit results, analyzes SimpleCov coverage, and supplies common Ruby autofix and dependency-audit commands.\n\nUse it for gems, scripts, services, Sinatra apps, Rails apps with Minitest, and any mixed repository with Ruby code. Rails-specific capabilities live in the Syrus Rails plugin so core Ruby support stays broadly applicable."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/ruby.svg"
    author "Thomas Kadauke"
    category "language"
    prepare_priority 10
    optionally_depends_on [ "test_insights" ]

    suggests_enabling "Ruby repositories get Bundler prepare, RSpec and RuboCop grader detail, SimpleCov coverage analysis, and autofix commands." do |signals|
      signals.repositories_detecting("ruby")
    end

    provides "test_insights:parser" => "Ruby::RspecParser"
    provides ecosystem: "Ruby::Ecosystem",
      implements: %i[detect_prepare grade_candidates grader_diagnostics review_criteria autofix dependency_audit focused_tests analyze_coverage],
      provisional: %i[affected_tests]
    provides ecosystem: "Ruby::RspecEcosystem", key: :rspec, implements: %i[grader_types]
    provides ecosystem: "Ruby::MinitestEcosystem", key: :minitest, implements: %i[grader_types]
  end
end
