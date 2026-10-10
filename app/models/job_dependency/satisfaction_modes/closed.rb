class JobDependency
  module SatisfactionModes
    class Closed < Base
      def dependency_succeeded?
        return dependency.depends_on_job.closed? if dependency.depends_on_job_id.present?
        return dependency.depends_on_epic.done? || dependency.depends_on_epic.archived? if dependency.depends_on_epic_id.present?

        dependency.referenced_epic&.then { |epic| epic.done? || epic.archived? } == true
      end
    end
  end
end
