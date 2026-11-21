module Python
  class Ecosystem
    class << self
      def key = :python
      def display_name = "Python"

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

      def grader_diagnostics(context)
        Array(GraderAugmentor.augment_grader_failure(
          name: context.name, command: context.command, workspace_path: context.workspace_path
        ))
      end

      def review_criteria(context) = context.repo_path ? ReviewCriteriaProvider.criteria(context.repo_path) : []

      def prompt_context(context)
        return nil unless context.repository || context.job

        PromptContext.call(repository: context.repository, job: context.job)
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
    end
  end

  class RuffEcosystem
    class << self
      def key = :python_ruff
      def display_name = "Ruff"
      def autofix(context)
        return nil unless context.workspace_path

        RuffFormatAutofix.autofix_command(workspace_path: context.workspace_path, changed_files: context.changed_files)
      end
    end
  end

  class BlackEcosystem
    class << self
      def key = :python_black
      def display_name = "Black"
      def autofix(context)
        return nil unless context.workspace_path

        BlackAutofix.autofix_command(workspace_path: context.workspace_path, changed_files: context.changed_files)
      end
    end
  end
end
