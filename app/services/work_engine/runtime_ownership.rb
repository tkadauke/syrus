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
        kinds: WorkDefinitions.epic_wide_kinds
      )
    end

    def active_landing_work?
      return false unless job

      WorkUnits::Ownership.active_for_job_kind?(job, WorkDefinitions.landing_lock_kinds) ||
        pending_preserved_merge_train_relaunch?
    end

    # A preserved merge train has no active WorkUnit between its failure and
    # its relaunch, but it still owns its members: the failure handler kept
    # the assembly and scheduled the relaunch. Treating that window as
    # orphaned let the reconciler defer the anchor Job, the relaunch was then
    # refused because the Job was "already approved", and teardown failed
    # every other member out of landing.
    def pending_preserved_merge_train_relaunch?
      train_ids = MergeTrain.active.joins(:members).where(merge_train_members: { job_id: job.id }).pluck(:id)
      return false if train_ids.empty?

      AutoRetryAttempt.pending
        .where(retry_kind: AutoRetryAttempt::PRESERVED_MERGE_TRAIN_RETRY_KIND)
        .includes(:workflow)
        .any? { |attempt| attempt.workflow && train_ids.include?(attempt.workflow.artifact("merge_train_id").to_i) }
    end

    private

    attr_reader :job
  end
end
