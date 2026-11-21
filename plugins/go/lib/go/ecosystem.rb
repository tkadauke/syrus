module Go
  class Ecosystem
    class << self
      def key = :go
      def display_name = "Go"

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

      def review_criteria(context) = context.repo_path ? ReviewCriteriaProvider.criteria(context.repo_path) : []

      def autofix(context)
        return nil unless context.workspace_path

        GofmtAutofix.autofix_command(workspace_path: context.workspace_path, changed_files: context.changed_files)
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

      def analyze_coverage(context)
        return nil unless context.artifact_path

        CoverageAnalyzer.call(artifact_path: context.artifact_path, format_hint: context.format_hint)
      end
    end
  end

  class TestEcosystem
    class << self
      def key = :go_test
      def display_name = "Go test"
      def grader_types(context)
        return nil if context.config.nil?

        TestGraderType.grade_steps(config: context.config, default_failures: context.default_failures)
      end
    end
  end
end
