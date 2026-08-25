module WorkEngine
  class RuntimeOwnership
    def self.active_epic_wide_workflow_for_job?(job)
      new(job).active_epic_wide_workflow?
    end

    def self.active_landing_work_for_job?(job)
      new(job).active_landing_work?
    end

    def initialize(job)
      @job = job
    end

    def active_epic_wide_workflow?
      return false unless job&.epic_id

      WorkUnits::Ownership.active_for_epic?(
        job.epic,
        kinds: WorkDefinitions.epic_wide_kinds,
        include_legacy: false
      )
    end

    def active_landing_work?
      return false unless job

      WorkUnits::Ownership.active_for_job_kind?(job, WorkDefinitions.landing_lock_kinds)
    end

    private

    attr_reader :job
  end
end
