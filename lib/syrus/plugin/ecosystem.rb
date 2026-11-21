# frozen_string_literal: true

module Syrus
  module Plugin
    # Language and toolchain contributions.
    module Ecosystem
      ReturnShape = Data.define(:description, :validator) do
        def valid?(value) = validator.call(value)
      end

      PREPARE_PLANS = ReturnShape.new(description: "Array<PreparePlan>",
        validator: ->(value) { value.is_a?(Array) && value.all? { |entry| entry.is_a?(PreparePlan) } })
      CI_LOG_RESULT = ReturnShape.new(description: "Hash with parser, error_summary, and error_block, or nil",
        validator: lambda { |value|
          value.nil? || (value.is_a?(Hash) && %i[parser error_summary error_block].all? do |key|
            value.key?(key) || value.key?(key.to_s)
          end)
        })
      REVIEW_PATTERNS = ReturnShape.new(description: "Array<String or Hash>",
        validator: ->(value) { value.is_a?(Array) && value.all? { |entry| entry.is_a?(String) || entry.is_a?(Hash) } })

      PreparePlan = Data.define(:detected, :commands, :version_file, :span_labels, :label) do
        def initialize(detected:, commands: [], version_file: nil, span_labels: [], label: nil)
          super(detected: !!detected, commands: Array(commands).dup.freeze, version_file:,
            span_labels: Array(span_labels).dup.freeze, label:)
        end

        def detected? = detected
      end

      DependencyAuditPlan = Data.define(:lockfiles, :command, :label) do
        def initialize(lockfiles:, command: nil, label: nil)
          super(lockfiles: Array(lockfiles).dup.freeze, command:, label:)
        end
      end

      module GraderCoverage
        COVERAGE_PHASES = %w[review].freeze

        def coverage_for_phases?(coverage, phases)
          coverage && (Array(phases).map(&:to_s) & COVERAGE_PHASES).any?
        end
      end

    end

    Ecosystem::DEFINITION = Family.define(:ecosystem) do
      shape :facet
      migrated
      indicates_language_support capability: :detect_prepare
      absorbs :prepare_detector, :grade_detector, :grader_type, :grader_augmentor,
        :review_criteria_provider, :autofix_command, :dependency_audit_command,
        :focused_test_command, :coverage_analyzer, :affected_test_analyzer,
        :ci_log_parser, :prompt_injector, :diff_review_file_pattern_provider,
        :build_system_graph_provider

      capability :detect_prepare, composition: :collect, absent: [], tier: :stable,
        context: Context::RepoContext, returns: Ecosystem::PREPARE_PLANS
      capability :grade_candidates, composition: :collect, absent: [], tier: :stable,
        context: Context::RepoContext, returns: Array
      capability :grader_types, composition: :keyed, absent: :configuration_error, decline: nil, tier: :stable,
        context: Context::GraderContext, returns: Array
      capability :grader_diagnostics, composition: :collect, absent: [], tier: :stable,
        context: Context::GraderContext, returns: [ Array, NilClass ]
      capability :review_criteria, composition: :collect, absent: [], tier: :stable,
        context: Context::RepoContext, returns: Array
      capability :prompt_context, composition: :collect, absent: [], decline: nil, tier: :stable,
        context: Context::JobContext, returns: [ String, NilClass ]
      capability :autofix, composition: :collect, absent: [], decline: nil, tier: :stable,
        context: Context::WorkspaceContext, returns: [ String, NilClass ]
      capability :dependency_audit, composition: :collect, absent: [], decline: nil, tier: :stable,
        context: Context::WorkspaceContext, returns: [ Ecosystem::DependencyAuditPlan, NilClass ]
      capability :focused_tests, composition: :first_claim, absent: nil, tier: :stable,
        context: Context::GraderContext, returns: [ String, NilClass ]
      capability :analyze_coverage, composition: :first_claim, absent: nil, tier: :stable,
        context: Context::WorkspaceContext, returns: Object
      capability :affected_tests, composition: :collect, absent: [], decline: nil, tier: :provisional,
        context: Context::WorkspaceContext, returns: [ Array, NilClass ]
      capability :parse_ci_log, composition: :first_claim, absent: nil, tier: :provisional,
        context: Context::GraderContext, returns: Ecosystem::CI_LOG_RESULT
      capability :review_file_patterns, composition: :collect, absent: [], tier: :provisional,
        context: Context::RepoContext, returns: Ecosystem::REVIEW_PATTERNS
      capability :target_graph, composition: :keyed, absent: :configuration_error, decline: nil, tier: :provisional,
        context: Context::RepoContext, returns: Object

    end

    def Ecosystem.restore_definition!
      Syrus::Plugin::Family.restore(Syrus::Plugin::Ecosystem::DEFINITION)
    end
  end

  module Host
    EcosystemGraderCoverage = Syrus::Plugin::Ecosystem::GraderCoverage unless const_defined?(:EcosystemGraderCoverage, false)
  end
end
