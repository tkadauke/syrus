module Ruby
  class Ecosystem
    class << self
      def key = :ruby
      def display_name = "Ruby"

      def detect_prepare(context)
        return [] unless context.repo_path && PrepareDetector.detect?(context.repo_path)

        [ Syrus::Host::EcosystemPreparePlan.new(
          detected: true,
          commands: PrepareDetector.prepare_commands(context.repo_path),
          version_file: PrepareDetector.mise_version_file,
          span_labels: PrepareDetector.span_labels,
          label: display_name
        ) ]
      end

      def grade_candidates(context) = context.repo_path ? GradeDetector.grade_candidates(context.repo_path) : []

      def grader_diagnostics(context)
        [ GraderAugmentor, RubocopGraderAugmentor ].flat_map do |provider|
          Array(provider.augment_grader_failure(
            name: context.name, command: context.command, workspace_path: context.workspace_path
          ))
        end
      end

      def review_criteria(context) = context.repo_path ? ReviewCriteriaProvider.criteria(context.repo_path) : []

      def autofix(context)
        return nil unless context.workspace_path

        RubocopAutofix.autofix_command(
          workspace_path: context.workspace_path, changed_files: context.changed_files
        )
      end

      def dependency_audit(context)
        lockfiles = BundlerAuditCommand.lockfiles
        changed = context.changed_files.map { |file| File.basename(file) }
        return nil if changed.any? && lockfiles.none? { |lockfile| changed.include?(lockfile) }

        Syrus::Host::EcosystemDependencyAuditPlan.new(
          lockfiles:,
          command: context.workspace_path && BundlerAuditCommand.audit_command(workspace_path: context.workspace_path),
          label: display_name
        )
      end

      FOCUSED_TEST_OPERATIONS = {
        prepare: lambda { |context|
          FocusedTestCommand.prepare_command_for(grader_name: context.name, grader_command: context.command)
        },
        isolated: lambda { |context|
          FocusedTestCommand.isolated_command_for(
            grader_name: context.name, grader_command: context.command, test_case: context.test_case
          )
        },
        command: lambda { |context|
          FocusedTestCommand.command_for(
            grader_name: context.name, grader_command: context.command, failed_cases: context.failed_cases,
            base_retry: context.base_retry, project_path: context.project_path
          )
        }
      }.freeze

      def focused_tests(context)
        FOCUSED_TEST_OPERATIONS.fetch(context.operation || :command).call(context)
      end

      def analyze_coverage(context)
        return nil unless context.artifact_path && SimpleCovAnalyzer.can_parse?(
          output_path: context.artifact_path, format_hint: context.format_hint
        )

        SimpleCovAnalyzer.call(output_path: context.artifact_path, format_hint: context.format_hint)
      end

      def affected_tests(context)
        return nil unless context.workspace_path

        AffectedTestAnalyzer.affected_files(
          repo_path: context.workspace_path, changed_files: context.changed_files
        )
      end
    end
  end

  class RspecEcosystem
    class << self
      def key = :rspec
      def display_name = "RSpec"
      def grader_types(context)
        return nil if context.config.nil?

        RspecGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end

  class MinitestEcosystem
    class << self
      def key = :minitest
      def display_name = "Minitest"
      def grader_types(context)
        return nil if context.config.nil?

        MinitestGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end
end
