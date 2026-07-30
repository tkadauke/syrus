module JobCodingMode
  extend ActiveSupport::Concern

  # --- Coding Mode lock ----------------------------------------------------

  def locked_by_coding_mode?
    linked_chat_id.present?
  end

  # Claim this Job for a Coding Mode chat session. Unapproves the Job first
  # if it is currently approved so the coding session can replace the
  # implement step. Returns false when the feature flag is off, the Job is
  # already locked, or the state is incompatible (i.e. not queued/implemented).
  def lock_for_coding_mode!(chat_session)
    return false unless Feature.coding_mode_enabled?
    return false if linked_chat_id.present?

    Job::ApprovalUnapprover.call(job: self, user: chat_session.user) if may_unapprove?
    return false unless may_claim_for_coding?

    self.linked_chat_id = chat_session.id
    claim_for_coding!
    save!
    true
  end

  # Cancel a Job that was freshly created for Coding Mode (no existing PR).
  # Clears the link and closes the Job.
  def cancel_new_coding_job!(reason: "cancelled")
    return false unless coding?

    update!(linked_chat_id: nil)
    cancel_active_runs_and_close!(reason)
  end

  # Signal that the coding session is complete and hand off to automation.
  # Transitions coding → implemented, fires a coding_handoff workflow that
  # runs graders, repairs grader failures in the workflow, and (on pass)
  # opens the PR. linked_chat_id is copied into workflow artifacts for
  # passive chat notifications, then cleared so the Job is no longer owned by
  # the originating chat while background workflow agents repair it.
  # Returns the new Workflow on success, false otherwise.
  def start_coding_handoff!(artifacts: nil)
    return false unless Feature.coding_mode_enabled?
    return false unless coding?

    chat_id = linked_chat_id
    handoff_artifacts = (artifacts || {}).dup
    handoff_artifacts["coding_handoff_chat_id"] ||= chat_id if chat_id.present?

    self.linked_chat_id = nil
    release_from_coding!
    save!

    workflow = Workflows::CodingHandoff.instantiate(job: self, artifacts: handoff_artifacts, agent_provider: agent_provider)
    StepDispatcher.start_workflow(workflow)
    workflow
  end

  # Release a taken-over Job from Coding Mode without discarding it.
  # Clears the link and returns the Job to :implemented, then drains any
  # automation workflows that were queued while the lock was held.
  def release_coding_mode_takeover!
    return false unless coding?

    update!(linked_chat_id: nil)
    release_from_coding! if may_release_from_coding?
    start_pending_workflows_if_dependencies_satisfied!
    true
  end

  # Hand off a Coding Mode Job to Syrus automation for grading.
  # Unlike release_coding_mode_takeover!, this KEEPS linked_chat_id so
  # grader results can be routed back to the owning chat session. Cancels
  # any held initial workflows (their implement step is no longer needed —
  # the coding session already did the implementation). The caller is
  # responsible for instantiating and starting a coding_handoff workflow.
  def complete_coding_handoff!
    return false unless coding?

    workflows.where(trigger_kind: "initial", state: "queued").find_each do |wf|
      wf.cancel! if wf.may_cancel?
      wf.save!
    end

    release_from_coding! if may_release_from_coding?
    save!
    true
  end
end
