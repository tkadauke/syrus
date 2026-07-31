module JobLifecycle
  extend ActiveSupport::Concern

  def mark_valid_and_queue!
    transaction do
      update!(
        state: closed? ? "triaging" : state,
        closure_reason: nil,
        finished_at: nil,
        validity: "valid",
        invalidation_reason: nil,
        invalidation_evidence: [],
        triaging_reason: "classifier_pending"
      )
    end
    advance_after_triage! if may_advance_after_triage?
  end

  def resolve_pending_epic_ref!(resolved_epic)
    return false unless triaging? && triaging_reason_pending_epic_ref?
    return false unless pending_epic_reference.to_h["github_issue_url"] == resolved_epic.github_issue_url

    update!(
      epic: resolved_epic,
      triaging_reason: "classifier_pending",
      pending_epic_reference: {}
    )
    advance_after_triage! if may_advance_after_triage?
    true
  end

  def closed_epic_reopenable?(closed_epic)
    return false unless closed_epic&.done?
    return false unless closed_epic.done_at

    Time.current - closed_epic.done_at <= user.epic_reopen_window.days
  end

  def start_pending_workflows_if_dependencies_satisfied!
    # If a job is stuck in blocked_by_epic because the epic unblock fired before
    # job-level deps were met, re-evaluate now that a dep may have resolved.
    release_epic_block! if may_release_epic_block? && dependencies_satisfied_for_execution?

    return false unless queued? || running? || implemented?
    return false unless stack_ready_for_execution?
    return false unless ready_for_execution?

    workflows.where(state: "queued").find_each do |workflow|
      workflow.association(:job).target = self
      StepDispatcher.start_workflow(workflow)
    end
    true
  end

  def restore_epic_block_if_not_started!
    return false unless queued?
    return false if runs.where(state: %w[running succeeded failed]).exists?

    transaction do
      workflows.where(state: "queued").find_each do |workflow|
        workflow.cancel!
        workflow.save!
      end

      block_by_epic! if may_block_by_epic?
    end
  end

  def pending_auto_merge?
    workflows.where(trigger_kind: "auto_merge").any? do |workflow|
      workflow.artifact("pending_auto_merge") == "waiting_for_parent"
    end
  end

  def log_pending_dependency_warnings!
    return if pending_dependency_warnings.blank?

    run = current_run
    return unless run

    pending_dependency_warnings.each do |warning|
      JobLog.append!(run: run, chunk: warning, kind: "system")
    end
    self.pending_dependency_warnings = []
  end

  def sync_skip_prepare_from_source!
    return skip_prepare? unless issue? && issue_number.present? && (repository.installation&.active? || user.github_token.present?)

    issue = GithubClient.for(repository: repository, user: user).fetch_issue(repository.slug, issue_number)
    names = Workflows.label_names(issue.labels)
    skip = names.include?(Workflows::SKIP_PREPARE_LABEL)

    updates = {}
    updates[:skip_prepare] = skip if skip_prepare? != skip
    update!(updates) if updates.any?

    skip
  end
end
