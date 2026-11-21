module JavaScript
  class Ecosystem
    class << self
      def key = :javascript
      def display_name = "JavaScript"

      def detect_prepare(context)
        return [] unless context.repo_path
        detected = PrepareDetector.detect?(context.repo_path)

        [ Syrus::Host::EcosystemPreparePlan.new(
          detected:,
          commands: detected ? PrepareDetector.prepare_commands(context.repo_path) : [],
          version_file: PrepareDetector.mise_version_file,
          span_labels: PrepareDetector.span_labels,
          label: display_name
        ) ]
      end

      def grade_candidates(context) = context.repo_path ? GradeDetector.grade_candidates(context.repo_path) : []

      def grader_diagnostics(context)
        Array(EslintGraderAugmentor.augment_grader_failure(
          name: context.name, command: context.command, workspace_path: context.workspace_path
        ))
      end

      def review_criteria(context) = context.repo_path ? ReviewCriteriaProvider.criteria(context.repo_path) : []

      def autofix(context)
        return nil unless context.workspace_path

        EslintAutofix.autofix_command(
          workspace_path: context.workspace_path, changed_files: context.changed_files
        )
      end

      def dependency_audit(context)
        lockfiles = DependencyAuditCommand.lockfiles
        changed = context.changed_files.map { |file| File.basename(file) }
        return nil if changed.any? && lockfiles.none? { |lockfile| changed.include?(lockfile) }

        Syrus::Host::EcosystemDependencyAuditPlan.new(
          lockfiles:,
          command: context.workspace_path && DependencyAuditCommand.audit_command(workspace_path: context.workspace_path),
          label: display_name
        )
      end

      FOCUSED_TEST_OPERATIONS = {
        prepare: ->(_context) { },
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
    end
  end

  class PrettierEcosystem
    class << self
      def key = :javascript_prettier
      def display_name = "Prettier"
      def autofix(context)
        return nil unless context.workspace_path

        PrettierAutofix.autofix_command(
          workspace_path: context.workspace_path, changed_files: context.changed_files
        )
      end
    end
  end

  class VitestEcosystem
    class << self
      def key = :vitest
      def display_name = "Vitest"
      def grader_types(context)
        return nil if context.config.nil?

        VitestGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end
end
