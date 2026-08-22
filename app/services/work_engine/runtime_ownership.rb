module WorkEngine
  class RuntimeOwnership
    def self.active_epic_wide_workflow_for_job?(job)
      new(job).active_epic_wide_workflow?
    end

    def initialize(job)
      @job = job
    end

    def active_epic_wide_workflow?
      return false unless job&.epic_id

      if WorkUnits::PathOwnership.work_unit_owned?("epic_wide_workflow")
        WorkUnits::Ownership.active_for_epic?(job.epic, kinds: Workflow::EPIC_WIDE_TRIGGER_KINDS)
      else
        legacy_active_epic_wide_workflow?
      end
    end

    private

    attr_reader :job

    def legacy_active_epic_wide_workflow?
      Workflow
        .active
        .epic_wide
        .where(job_id: job.epic.jobs.select(:id))
        .exists?
    end
  end
end
