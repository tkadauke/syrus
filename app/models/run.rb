class Run < ApplicationRecord
  include AASM
  include RecordsStateTransitions
  include BroadcastsJobProgress

  TRIGGER_KINDS = Workflow::TriggerKind.values

  belongs_to :job
  belongs_to :user
  # Step is optional during the migration window: existing Runs
  # (and the existing direct-create paths in Job#after_create_commit
  # and the polling jobs) still link to Job. Once those code paths
  # have moved to instantiate Workflows + Steps, a follow-up migration
  # backfills runs.step_id on every existing Run and flips the
  # belongs_to to required.
  belongs_to :step, optional: true
  has_many :job_logs, -> { order(:sequence) }, dependent: :destroy
  has_many :mcp_tool_usages, dependent: :nullify
  has_many :run_health_snapshots, -> { order(:created_at) }, dependent: :destroy
  has_many :auto_retry_attempts, dependent: :nullify
  has_many :spawned_processes, dependent: :nullify
  has_many :command_spans, -> { order(:sequence, :id) }, dependent: :destroy
  has_one :claude_session, as: :resumable, dependent: :destroy
  has_one :claude_session_metadata,
          -> { metadata_only },
          as: :resumable,
          class_name: "ClaudeSession"
  has_one :run_diagnostic, dependent: :destroy
  has_one :run_failure_classification, dependent: :destroy
  has_one :run_resource_summary, dependent: :destroy

  # Convenience walk up to Workflow when step is set.
  def workflow
    step&.workflow
  end

  def workflow_id
    step&.workflow_id
  end

  validates :trigger_kind, presence: true, inclusion: { in: TRIGGER_KINDS }
  validates :agent_provider, presence: true, inclusion: { in: -> { User.agent_providers } }
  validate :user_matches_execution_graph
  before_validation :default_user_from_job, on: :create

  # Backstop for genuine agent hangs (claude alive but making no
  # progress). Rare in practice — claude almost always streams a chunk
  # at least every few minutes. The reaper's PRIMARY signal is the
  # SolidQueue claim being gone (worker died → claim released by SQ
  # supervisor); this threshold only triggers when the claim is still
  # alive but the agent itself stopped emitting transcript output.
  # 30 min comfortably covers normal long-tool-call gaps (large file
  # reads, broad greps, multi-file edits).
  STALE_HEARTBEAT_THRESHOLD = 30.minutes
  WORKER_DIED_STEP_MAX_RETRIES = 3

  scope :active, -> { where(state: %w[ queued running ]) }
  scope :terminal, -> { where(state: %w[ succeeded failed cancelled ]) }
  scope :ordered, -> { order(:created_at) }
  # Currently-executing agent Runs across the cluster — the `:runs`-queue
  # workflows subject to the global agent-concurrency cap. App-DB counted, so
  # it holds across worker pods and is testable without SolidQueue tables.
  scope :running_agent_runs, -> {
    where(state: "running")
      .joins(step: :workflow)
      .where(workflows: { trigger_kind: Workflow.runs_queue_trigger_kinds })
  }
  scope :stale, -> {
    t = STALE_HEARTBEAT_THRESHOLD.ago
    where(state: "running")
      .where("last_heartbeat_at < :t OR (last_heartbeat_at IS NULL AND started_at < :t)", t: t)
  }

  aasm column: :state, whiny_transitions: false do
    after_all_transitions :record_state_transition!
    state :queued, initial: true
    state :running, :succeeded, :failed, :cancelled

    event :start do
      transitions from: :queued, to: :running, after: -> { self.started_at = Time.current }
    end

    event :succeed do
      transitions from: :running, to: :succeeded, after: -> { self.finished_at = Time.current }
    end

    event :fail do
      transitions from: [ :queued, :running ], to: :failed, after: -> { self.finished_at = Time.current }
    end

    event :cancel do
      transitions from: [ :queued, :running ], to: :cancelled, after: -> { self.finished_at = Time.current }
    end
  end

  after_create_commit :enqueue_run_job

  # Operator-initiated stop: when a Run is cancelled mid-flight via
  # the Stop button, the chain can't continue (v1 has no intra-step
  # retry). Cascade the cancel up to the Step and Workflow so the
  # whole burst goes terminal — workspace teardown then fires via
  # Workflow's terminal-state callback.
  #
  # Does NOT fire when the Run was cancelled by RunJob's pre-flight
  # guard against an already-terminal Workflow — that path's
  # workflow.may_cancel? is false (workflow is already
  # succeeded/failed/cancelled), so this is a no-op there.
  after_update_commit :cascade_cancel_to_workflow!,
                       if: :saved_change_to_state_to_cancelled?
  after_update_commit :cascade_failure_to_step!,
                       if: :saved_change_to_state_to_failed?
  after_update_commit :classify_failure!,
                       if: :saved_change_to_state_to_failed?
  after_update_commit :record_provider_failure_evidence!,
                       if: :saved_change_to_state_to_failed?
  after_update_commit :broadcast_provider_availability_after_failure!,
                       if: :saved_change_to_state_to_failed?
  after_update_commit :record_provider_success_evidence!,
                       if: :saved_change_to_state_to_succeeded?
  after_update_commit :broadcast_provider_availability_after_success!,
                       if: :saved_change_to_state_to_succeeded?
  after_update_commit :refresh_resource_summary_after_completion!,
                       if: :saved_change_to_state_to_terminal?

  def saved_change_to_state_to_cancelled?
    saved_change_to_state? && state == "cancelled"
  end

  def saved_change_to_state_to_failed?
    saved_change_to_state? && state == "failed"
  end

  def saved_change_to_state_to_succeeded?
    saved_change_to_state? && state == "succeeded"
  end

  def saved_change_to_state_to_terminal?
    saved_change_to_state? && terminal?
  end

  def cascade_cancel_to_workflow!
    return unless step
    if step.may_cancel?
      step.cancel!
      step.save!
    end
    wf = step.workflow
    if wf.may_cancel?
      wf.cancel!
      wf.save!
    end
  end

  def cascade_failure_to_step!
    return unless step
    return if retried_in_place_after_worker_died?

    if step.may_fail?
      step.fail!
      step.save!
    end
    StepDispatcher.fail_from(step.reload) if step.failed?
  end

  def initial?
    trigger_kind == "initial"
  end

  # Rebase Runs are maintenance attempts on an existing PR's branch —
  # they DON'T progress the Job's state. RunJob takes a different code
  # path for them: skip the closed-Job guard, skip commit_agent_changes
  # (the rebase rewrites history rather than modifying the working
  # tree), force-push-with-lease, and skip the PR-opening step.
  def rebase?
    trigger_kind == "rebase"
  end

  # Resume Runs continue an agent session whose worker died
  # mid-flight. RunJob restores the prior session's JSONL to disk
  # before invoking the provider's resume path, and uses Prompts::Resume
  # as the new prompt so the agent knows what just happened.
  def resume?
    trigger_kind == "resume"
  end

  def terminal?
    succeeded? || failed? || cancelled?
  end

  def cost_breakdown?
    cost_usd.present? ||
      input_tokens.present? ||
      output_tokens.present? ||
      cache_creation_input_tokens.present? ||
      cache_read_input_tokens.present?
  end

  # True when this Run's workflow runs on the `:runs` queue — compute work
  # subject to the global agent-concurrency cap
  # (AppSetting.max_concurrent_agent_runs). This includes main-branch graders.
  # Landing/merge runs are not capped.
  def agent_queue?
    workflow_template_class.queue_name == :runs
  end

  # Sanctioned re-dispatch for a non-terminal Run that lost its
  # SolidQueue::Job (e.g. an inline-drive successor orphaned when the
  # worker died before picking it up — see ReapStaleRunsJob). Reuses
  # the same queue + priority logic as the create-commit enqueue.
  def reenqueue!
    enqueue_run_job
  end

  # When this workflow already ran on a durable worker data root that still has
  # a live consumer, route back to that storage-specific resume queue so it can
  # see the existing on-disk workspace. Returns nil when no storage key was
  # recorded, or for legacy hostname-only rows when that worker pod is gone.
  # Public so callers like DiagnoseRunJob dispatch can use the same routing logic.
  def resume_worker_queue
    storage_key = workflow&.worker_storage_key.presence
    if storage_key.present?
      queue = Workflow.resume_queue_name(storage_key)
      return queue if InstanceVersion.worker_queue_live?(queue)
      return nil
    end

    host = workflow&.worker_hostname
    return nil if host.blank?
    return nil unless InstanceVersion.worker_live?(host)

    Workflow.resume_queue_name(host)
  end

  def solid_queue_priority
    workflow_template_class.solid_queue_priority(job)
  end

  private

  def retried_in_place_after_worker_died?
    return false if step.agentic?

    classification = RunFailureClassifier.classify(self)
    return false unless classification.classification == AutoRetryAttempt::WORKER_DIED_CLASSIFICATION

    prior_worker_died_count = step.runs
      .where.not(id: id)
      .where(state: "failed")
      .joins(:run_failure_classification)
      .where(run_failure_classifications: { classification: AutoRetryAttempt::WORKER_DIED_CLASSIFICATION })
      .count

    return false unless prior_worker_died_count < WORKER_DIED_STEP_MAX_RETRIES

    StepDispatcher.create_run_and_enqueue(step, step.workflow)
    Rails.logger.info(
      "[Run##{id}] worker_died in-place retry #{prior_worker_died_count + 1}/#{WORKER_DIED_STEP_MAX_RETRIES}: " \
      "new run queued on step #{step.id} (#{step.kind})"
    )
    true
  rescue StandardError => e
    Rails.logger.warn("[Run##{id}] worker_died in-place retry failed: #{e.class}: #{e.message}")
    false
  end

  def default_user_from_job
    self.user ||= job&.user
  end

  def user_matches_execution_graph
    errors.add(:user, "must match the Job owner") if user_id.present? && job.present? && user_id != job.user_id

    return if step.blank?

    workflow = step.workflow
    if job_id.present? && workflow&.job_id.present? && job_id != workflow.job_id
      errors.add(:step, "must belong to the same Job as the Run")
    end

    if user_id.present? && workflow&.user_id.present? && user_id != workflow.user_id
      errors.add(:user, "must match the Workflow owner")
    end
  end

  def job_for_progress_broadcast
    job
  end

  def classify_failure!
    RunFailureClassifier.persist!(self)
  rescue StandardError => e
    Rails.logger.warn("[RunFailureClassifier] failed for Run ##{id}: #{e.class}: #{e.message}")
    nil
  end

  def record_provider_failure_evidence!
    return unless agent_provider == "codex"
    return unless step.nil? || step.agentic?

    text = [
      agent_outcome,
      run_failure_classification&.classification,
      run_diagnostic&.error_class,
      run_diagnostic&.error_message
    ].compact.join(" ")
    return if ProviderUsageLimit.inconclusive?(text)
    return unless agent_outcome.to_s == ProviderUsageLimit::OUTCOME ||
      run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION ||
      ProviderUsageLimit.detect?(text)

    ProviderAvailabilityEvidence.record_codex_invocation_failure!(
      run: self,
      model: ProviderUsageLimit.extract_model(text),
      message: text,
      observed_at: finished_at || Time.current
    )
  rescue StandardError => e
    Rails.logger.warn("[ProviderAvailabilityEvidence] failed to record Codex failure for Run ##{id}: #{e.class}: #{e.message}")
    nil
  end

  def record_provider_success_evidence!
    return unless agent_provider == "codex"
    return unless step.nil? || step.agentic?

    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "run_success",
      model: CodexInvocation.configured_model,
      run: self,
      observed_at: finished_at || Time.current,
      details: {
        outcome: agent_outcome,
        workflow_id: workflow_id,
        job_id: job_id,
        step_kind: step&.kind
      }
    )
  rescue StandardError => e
    Rails.logger.warn("[ProviderAvailabilityEvidence] failed to record Codex success for Run ##{id}: #{e.class}: #{e.message}")
    nil
  end

  def broadcast_provider_availability_after_failure!
    return if agent_provider.blank?

    availability = App::ProviderAvailability.broadcast_changed(user: user, provider: agent_provider)
    retry_after = availability&.dig(:retry_after)
    ProviderAvailabilityBroadcastJob.set(wait_until: Time.zone.parse(retry_after)).perform_later(user_id, agent_provider) if retry_after.present?
  rescue StandardError => e
    Rails.logger.warn("[ProviderAvailability] failed to broadcast for Run ##{id}: #{e.class}: #{e.message}")
    nil
  end

  def broadcast_provider_availability_after_success!
    return if agent_provider.blank?

    App::ProviderAvailability.broadcast_changed(user: user, provider: agent_provider)
  rescue StandardError => e
    Rails.logger.warn("[ProviderAvailability] failed to broadcast success for Run ##{id}: #{e.class}: #{e.message}")
    nil
  end

  def refresh_resource_summary_after_completion!
    RunResourceSummary.refresh_for(self)
  end

  def enqueue_run_job
    return if terminal?
    # When a RunJob is currently driving this workflow inline, the
    # next Step's Run was just created by StepDispatcher and should
    # not bounce through SolidQueue. Runs created for other workflows
    # in the same thread still need their own queue dispatch.
    current_workflow_id = Thread.current[:syrus_current_run]&.workflow_id
    return if current_workflow_id && current_workflow_id == workflow_id

    queue = resume_worker_queue || workflow_template_class.queue_name
    RunJob.set(queue: queue, priority: solid_queue_priority).perform_later(id)
  end

  def workflow_template_class
    Workflows.for(trigger_kind: workflow&.trigger_kind || trigger_kind)
  end
end
