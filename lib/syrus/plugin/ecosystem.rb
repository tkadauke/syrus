# frozen_string_literal: true

module Syrus
  module Plugin
    # Language and toolchain contributions. This definition is the migration
    # boundary for the legacy ecosystem extension points below.
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

      module Adapters
        module_function

        def repo(path = nil, config: nil) = Context::RepoContext.new(repo_path: path, config:)
        def workspace(path = nil, changed_files: [], artifact_path: nil, format_hint: nil)
          Context::WorkspaceContext.new(workspace_path: path, changed_files:, artifact_path:, format_hint:)
        end
        def grader(**attributes) = Context::GraderContext.new(**attributes)
        def plan(provider, path = nil)
          plan = Array(provider.detect_prepare(repo(path))).first
          return unless plan
          return plan if plan.label

          plan.with(label: provider.respond_to?(:display_name) ? provider.display_name : provider.name)
        end

        module Prepare
          module_function
          def dispatch(provider, context)
            detected = context.repo_path && provider.detect?(context.repo_path)
            [ PreparePlan.new(detected:, commands: detected ? provider.prepare_commands(context.repo_path) : [],
              version_file: provider.mise_version_file, span_labels: provider.span_labels,
              label: provider.respond_to?(:name) ? provider.name : provider.to_s) ]
          end
          def detect?(provider, repo_path) = !!Adapters.plan(provider, repo_path)&.detected?
          def prepare_commands(provider, repo_path)
            result = Adapters.plan(provider, repo_path)
            result&.detected? ? result.commands : []
          end
          def mise_version_file(provider) = Adapters.plan(provider)&.version_file
          def span_labels(provider) = Adapters.plan(provider)&.span_labels || []
        end

        module GradeCandidates
          module_function
          def dispatch(provider, context) = provider.grade_candidates(context.repo_path)
          def grade_candidates(provider, repo_path) = provider.grade_candidates(Adapters.repo(repo_path))
        end

        module GraderTypes
          module_function
          def key(provider) = provider.type_name
          def dispatch(provider, context)
            provider.grade_steps(config: context.config, default_failures: context.default_failures)
          rescue ArgumentError => e
            raise Dispatch::ValidationError, e.message
          end
          def type_name(provider) = provider.key
          def grade_steps(provider, config:, default_failures:)
            provider.grader_types(Adapters.grader(config:, default_failures:))
          end
        end

        module GraderDiagnostics
          module_function
          def dispatch(provider, context)
            provider.augment_grader_failure(name: context.name, command: context.command, workspace_path: context.workspace_path)
          end
          def augment_grader_failure(provider, name:, command:, workspace_path:)
            provider.grader_diagnostics(Adapters.grader(name:, command:, workspace_path:))
          end
        end

        module ReviewCriteria
          module_function
          def dispatch(provider, context) = provider.criteria(context.repo_path)
          def criteria(provider, repo_path) = provider.review_criteria(Adapters.repo(repo_path))
        end

        module Autofix
          module_function
          def dispatch(provider, context)
            provider.autofix_command(workspace_path: context.workspace_path, changed_files: context.changed_files)
          rescue ArgumentError => e
            raise unless e.message.include?("unknown keyword: :changed_files")
            provider.autofix_command(workspace_path: context.workspace_path)
          end
          def autofix_command(provider, workspace_path:, changed_files: [])
            provider.autofix(Adapters.workspace(workspace_path, changed_files:))
          end
        end

        module DependencyAudit
          module_function
          def dispatch(provider, context)
            lockfiles = provider.lockfiles
            changed = context.changed_files.map { |file| File.basename(file) }
            return DependencyAuditPlan.new(lockfiles:, label: provider.to_s.split("::").first) if changed.empty?
            return nil unless lockfiles.any? { |lockfile| changed.include?(lockfile) }

            DependencyAuditPlan.new(lockfiles:,
              command: provider.audit_command(workspace_path: context.workspace_path), label: provider.to_s.split("::").first)
          end
          def lockfiles(provider)
            Array(provider.dependency_audit(Adapters.workspace)).first&.lockfiles || []
          end
          def audit_command(provider, workspace_path:)
            Array(provider.dependency_audit(Adapters.workspace(workspace_path))).first&.command
          end
        end

        module FocusedTests
          module_function
          LEGACY_OPERATIONS = {
            prepare: lambda { |provider, context|
              provider.prepare_command_for(grader_name: context.name, grader_command: context.command)
            },
            isolated: lambda { |provider, context|
              provider.isolated_command_for(grader_name: context.name, grader_command: context.command,
                test_case: context.test_case) if provider.respond_to?(:isolated_command_for)
            },
            command: lambda { |provider, context|
              provider.command_for(grader_name: context.name, grader_command: context.command,
                failed_cases: context.failed_cases, base_retry: context.base_retry, project_path: context.project_path)
            }
          }.freeze

          def dispatch(provider, context)
            LEGACY_OPERATIONS.fetch(context.operation || :command).call(provider, context)
          rescue ArgumentError => e
            raise unless e.message.include?("unknown keyword: :project_path")
            provider.command_for(grader_name: context.name, grader_command: context.command,
              failed_cases: context.failed_cases, base_retry: context.base_retry)
          end
          def command_for(provider, grader_name:, grader_command:, failed_cases:, base_retry:, project_path: nil)
            provider.focused_tests(Adapters.grader(name: grader_name, command: grader_command, failed_cases:,
              base_retry:, project_path:, operation: :command))
          end
          def prepare_command_for(provider, grader_name:, grader_command:)
            provider.focused_tests(Adapters.grader(name: grader_name, command: grader_command, operation: :prepare))
          end
          def isolated_command_for(provider, grader_name:, grader_command:, test_case:)
            provider.focused_tests(Adapters.grader(name: grader_name, command: grader_command, test_case:,
              operation: :isolated))
          end
        end

        module Coverage
          module_function
          def dispatch(provider, context) = provider.call(artifact_path: context.artifact_path, format_hint: context.format_hint)
          def call(provider, artifact_path:, format_hint: nil)
            provider.analyze_coverage(Adapters.workspace(artifact_path&.dirname, artifact_path:, format_hint:))
          end
        end

        module AffectedTests
          module_function
          def dispatch(provider, context) = provider.affected_files(repo_path: context.workspace_path, changed_files: context.changed_files)
          def affected_files(provider, repo_path:, changed_files:)
            provider.affected_tests(Adapters.workspace(repo_path, changed_files:))
          end
        end

        module CiLog
          module_function
          def dispatch(provider, context) = provider.call(text: context.text, step_name: context.step_name)
          def call(provider, text:, step_name: nil)
            provider.parse_ci_log(Adapters.grader(text:, step_name:))
          end
        end

        module Prompt
          module_function
          def dispatch(provider, context) = provider.call(repository: context.repository, job: context.job)
          def call(provider, repository:, job:)
            provider.prompt_context(Context::JobContext.new(repository:, job:))
          end
        end

        module ReviewPatterns
          module_function
          def dispatch(provider, _context) = provider.diff_review_file_patterns
          def diff_review_file_patterns(provider) = provider.review_file_patterns(Adapters.repo)
        end

        module TargetGraph
          module_function
          def key(provider) = provider.provider_key
          def dispatch(provider, context) = provider.import_target_graph(repo_path: context.repo_path, config: context.config)
          def provider_key(provider) = provider.key
          def import_target_graph(provider, repo_path:, config:)
            provider.target_graph(Adapters.repo(repo_path, config:))
          end
        end
      end
    end

    Ecosystem::DEFINITION = Family.define(:ecosystem) do
      shape :facet
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
      capability :grader_diagnostics, composition: :broadcast, absent: nil, tier: :stable,
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

      legacy :prepare_detector, capability: :detect_prepare, adapter: Ecosystem::Adapters::Prepare
      legacy :grade_detector, capability: :grade_candidates, adapter: Ecosystem::Adapters::GradeCandidates
      legacy :grader_type, capability: :grader_types, adapter: Ecosystem::Adapters::GraderTypes
      legacy :grader_augmentor, capability: :grader_diagnostics, adapter: Ecosystem::Adapters::GraderDiagnostics
      legacy :review_criteria_provider, capability: :review_criteria, adapter: Ecosystem::Adapters::ReviewCriteria
      legacy :autofix_command, capability: :autofix, adapter: Ecosystem::Adapters::Autofix
      legacy :dependency_audit_command, capability: :dependency_audit, adapter: Ecosystem::Adapters::DependencyAudit
      legacy :focused_test_command, capability: :focused_tests, adapter: Ecosystem::Adapters::FocusedTests
      legacy :coverage_analyzer, capability: :analyze_coverage, adapter: Ecosystem::Adapters::Coverage
      legacy :affected_test_analyzer, capability: :affected_tests, adapter: Ecosystem::Adapters::AffectedTests
      legacy :ci_log_parser, capability: :parse_ci_log, adapter: Ecosystem::Adapters::CiLog
      legacy :prompt_injector, capability: :prompt_context, adapter: Ecosystem::Adapters::Prompt
      legacy :diff_review_file_pattern_provider, capability: :review_file_patterns, adapter: Ecosystem::Adapters::ReviewPatterns
      legacy :build_system_graph_provider, capability: :target_graph, adapter: Ecosystem::Adapters::TargetGraph
    end

    def Ecosystem.restore_definition!
      Syrus::Plugin::Family.restore(Syrus::Plugin::Ecosystem::DEFINITION)
    end
  end
end
