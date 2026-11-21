module WorkEngine
  # Whether an active MergeTrain still has something driving it. The stale
  # train classifier and its repair both ask this, so the repair never fails a
  # train the classifier would have left alone (formal/SyrusModel/Agreement.lean).
  class MergeTrainOwnership
    # A preserved train's relaunch may sit this far either side of now and
    # still count as its owner; past it the train is reaped and its approved
    # members go to a fresh one.
    RELAUNCH_GRACE = 10.minutes
    # `blocked` belongs with `queued` and `running`: a merge-train workflow
    # waiting on admission (no capable worker, main-branch health) still owns
    # its train, and reaping the train out from under it loses an assembly
    # that was about to start.
    OWNING_WORKFLOW_STATES = %w[queued running blocked].freeze

    def self.pending_relaunches
      AutoRetryAttempt
        .pending
        .where(scheduled_at: RELAUNCH_GRACE.ago..RELAUNCH_GRACE.from_now)
        .includes(workflow: :workflow_artifact_values)
        .to_a
        .select { |attempt| attempt.workflow&.trigger_kind == "merge_train" }
    end

    def initialize(train, pending_relaunches: nil)
      @train = train
      @pending_relaunches = pending_relaunches
    end

    def owned?
      active_workflow_ids.any? || active_work_unit_ids.any? || relaunch_pending?
    end

    def active_workflow_ids
      @active_workflow_ids ||= Workflow
        .where(trigger_kind: "merge_train", state: OWNING_WORKFLOW_STATES)
        .select(:id)
        .preload(:workflow_artifact_values)
        .filter_map { |workflow| workflow.id if workflow.artifact("merge_train_id").to_i == train.id }
    end

    def active_work_unit_ids
      @active_work_unit_ids ||= begin
        kind = train.epic_id.present? ? "merge_train" : "job_bundle"
        scope_type = train.epic_id.present? ? "epic" : "repository"
        scope_id = train.epic_id.presence || train.repository_id

        WorkUnit
          .where(kind: kind, scope_type: scope_type, scope_id: scope_id, state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
          .pluck(:id)
      end
    end

    # A preserved train's workflow is `failed` by design -- that is what
    # preservation means -- so it never shows up as active runtime. The pending
    # AutoRetryAttempt *is* the owner here, and it stops being one the moment it
    # is performed or skipped.
    def relaunch_pending?
      (@pending_relaunches || self.class.pending_relaunches).any? do |attempt|
        attempt.workflow&.artifact("merge_train_id").to_i == train.id
      end
    end

    private

    attr_reader :train
  end
end
