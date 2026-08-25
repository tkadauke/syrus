module InputSources
  class PendingWorkWakeup
    def self.call(repository)
      new(repository).call
    end

    def initialize(repository)
      @repository = repository
    end

    def call
      ids = pending_job_ids
      return 0 if ids.empty?

      count = 0
      Job.where(id: ids).open_threads.find_each do |job|
        count += 1 if job.start_pending_workflows_if_dependencies_satisfied!
      end
      count
    end

    private

    attr_reader :repository

    def pending_job_ids
      (
        queued_workflow_job_ids +
        requested_intent_job_ids +
        active_work_unit_job_ids
      ).compact.uniq
    end

    def queued_workflow_job_ids
      Workflow
        .joins(:job)
        .where(state: "queued", jobs: { repository_id: repository.id })
        .distinct
        .pluck(:job_id)
    end

    def requested_intent_job_ids
      WorkIntent
        .where(repository_id: repository.id, scope_type: "job", state: %w[requested waiting])
        .distinct
        .pluck(:scope_id)
    end

    def active_work_unit_job_ids
      WorkUnitMember
        .joins(:work_unit)
        .where(work_units: { repository_id: repository.id, state: WorkUnits::Ownership::ACTIVE_STATES })
        .distinct
        .pluck(:job_id)
    end
  end
end
