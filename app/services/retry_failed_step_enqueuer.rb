class RetryFailedStepEnqueuer
  # Genuine last-resort case: the workflow workspace is gone, so there is no
  # in-place recovery left and Start Over really is the only path forward.
  WORKSPACE_CLEANED_UP_MESSAGE = "Workspace already cleaned up - use Start over.".freeze
  ACTIVE_WORK_LOCK_ERROR = "active_work_lock".freeze

  Result = Data.define(:run, :workflow, :step, :error) do
    def success? = run.present?
    def active_work_lock? = error.to_s.start_with?("#{ACTIVE_WORK_LOCK_ERROR}:")
  end

  def self.call(...) = new(...).call
  def self.failed_step_for(workflow)
    workflow.steps.where(state: "failed").reorder(position: :desc, id: :desc).first
  end

  def initialize(workflow:, parent_session_id: nil, prompt: nil, agent_provider: nil, disable_session_resume: false)
    @workflow = workflow
    @parent_session_id = parent_session_id
    @prompt = prompt
    @agent_provider = agent_provider.to_s.presence
    @disable_session_resume = disable_session_resume
  end

  def call
    return failure("Workflow is not in a failed state.") unless workflow.failed?
    return failure(WORKSPACE_CLEANED_UP_MESSAGE) unless workflow.retry_available?

    failed_step = self.class.failed_step_for(workflow)
    return failure("No failed step to retry.") unless failed_step
    return rebuild_merge_train if retry_policy.rebuild_unit?(failed_step)
    return failure("Failed step requires a new workflow attempt.") unless retry_policy.continuation?(failed_step)
    if (lock_error = active_work_lock_error)
      return failure(lock_error)
    end

    workflow.reopen!
    workflow.save!
    failed_step.reopen!
    failed_step.save!
    revive_cancelled_downstream_steps!(failed_step)

    if workflow.landing_workflow?
      job = workflow.job
      job.update_columns(landing_failure_reason: nil) if job.landing_failure_reason.present?
    end

    run = failed_step.runs.create!(
      job: workflow.job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: agent_provider || workflow.agent_provider,
      parent_session_id: retry_parent_session_id,
      prompt: prompt
    )

    Result.new(run: run, workflow: workflow, step: failed_step, error: nil)
  rescue WorkUnits::Launcher::LockConflict => e
    failure("#{ACTIVE_WORK_LOCK_ERROR}: active WorkUnit ##{e.work_unit.id} already owns #{e.lock_key}")
  end

  private

  attr_reader :workflow, :parent_session_id, :prompt, :agent_provider, :disable_session_resume

  def retry_parent_session_id
    return Steps::Base::DISABLE_AGENT_RESUME if disable_session_resume

    parent_session_id
  end

  def retry_policy
    workflow.work_definition.retry_policy
  end

  def active_work_lock_error
    lock_keys_for_retry.each do |lock_key|
      owner = WorkUnits::Ownership.active_unit_for_lock_key(lock_key)
      next unless owner
      next if same_runtime_lock_owner?(owner)

      return "#{ACTIVE_WORK_LOCK_ERROR}: active WorkUnit ##{owner.id} already owns #{lock_key}"
    end

    nil
  end

  def lock_keys_for_retry
    workflow.work_definition.lock_keys_for(
      job: workflow.job,
      member_jobs: member_jobs_for_retry,
      artifacts: workflow.artifacts.to_h
    )
  end

  def member_jobs_for_retry
    unit = workflow.work_unit
    jobs = unit&.work_unit_members&.includes(:job)&.order(:id)&.map(&:job)&.compact
    jobs.presence || [ workflow.job ].compact
  end

  def same_runtime_lock_owner?(owner)
    unit = workflow.work_unit
    return false unless owner && unit
    return true if owner.id.to_i == unit.id.to_i

    owner.workflow_id.present? && owner.workflow_id.to_i == workflow.id.to_i
  end

  def revive_cancelled_downstream_steps!(failed_step)
    cursor = failed_step.next_step
    while cursor
      if cursor.cancelled? && cursor.runs.none?
        cursor.update_columns(
          state: "queued",
          started_at: nil,
          finished_at: nil,
          updated_at: Time.current
        )
      end
      cursor = cursor.next_step
    end
  end

  def rebuild_merge_train
    train_id = workflow.artifact("merge_train_id")
    train = MergeTrain.find_by(id: train_id)
    return failure("Merge train record not found - contact an admin or operator to rebuild the merge train.") unless train

    rebuild = rebuild_train(train)
    rebuilt_workflow = rebuild.workflow
    unless rebuilt_workflow
      reason = rebuild_blocker_reason(train).presence ||
        "merge-train dispatch was blocked by a concurrent state change"
      return failure("#{train_rebuild_label(train)} is not ready for a merge-train rebuild: #{reason}.")
    end

    run = rebuilt_workflow.runs.order(:created_at).last
    return failure("Merge-train rebuild did not enqueue a run.") unless run

    Result.new(run: run, workflow: rebuilt_workflow, step: run.step, error: nil)
  end

  def rebuild_train(train)
    if train.bundle_backed?
      JobBundleRetrier.rebuild_merge_train!(train.repository, source_train: train)
    else
      EpicLandingRetrier.rebuild_merge_train!(train.epic, source_train: train)
    end
  end

  def rebuild_blocker_reason(train)
    if train.bundle_backed?
      JobBundleDispatcher.blocker_reason(train.repository, bypass_cooldown: true)
    else
      MergeTrainDispatcher.blocker_reason(train.epic, bypass_cooldown: true)
    end
  end

  def train_rebuild_label(train)
    train.bundle_backed? ? "Job bundle" : "Epic"
  end

  def failure(message)
    Result.new(run: nil, workflow: workflow, step: nil, error: message)
  end
end
