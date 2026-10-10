class JobDependency
  module SatisfactionModes
    class Success < Base
      def dependency_succeeded?
        return dependency.depends_on_epic.done? if dependency.depends_on_epic_id.present?
        return resolved_dependency_succeeded? if dependency.resolved?

        dependency.referenced_epic&.done? == true
      end

      def execution_dependency_satisfied?
        return false if dependency.dependency_approval_withdrawn_for_execution?

        dependency_succeeded? || dependency_ready_for_execution?
      end

      private

      def resolved_dependency_succeeded?
        dependency.depends_on_job.dependency_succeeded? || dependency.same_epic_dependency_approved?
      end

      def dependency_ready_for_execution?
        return false unless dependency.depends_on_job

        dependency.depends_on_job.implemented? &&
          dependency.depends_on_job.pr_number.present? &&
          dependency.depends_on_job.branch_name.present? &&
          dependency.depends_on_job.head_sha.present?
      end
    end
  end
end
