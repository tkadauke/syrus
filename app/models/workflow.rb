class Workflow < ApplicationRecord
  include AASM
  include RecordsStateTransitions
  include BroadcastsJobProgress

  TRIGGER_KINDS = Workflow::TriggerKind.values
  EPIC_WIDE_TRIGGER_KINDS = Workflow::TriggerKind.epic_wide_values

  belongs_to :job
  belongs_to :user
  has_many :steps, -> { order(:position) }, dependent: :destroy
  has_many :run_resource_summaries, dependent: :destroy
  has_many :mcp_tool_usages, dependent: :nullify
  has_many :auto_retry_attempts, dependent: :destroy
  has_one_attached :coverage_hit_map

  validates :trigger_kind, presence: true, inclusion: { in: TRIGGER_KINDS }
  validates :agent_provider, presence: true, inclusion: { in: -> { User.agent_providers } }
  validate :user_matches_job
  validate :job_must_be_open_on_create, on: :create
  before_validation :default_user_from_job, on: :create

  # Free-form bag of artifacts produced during this workflow. The
  # MCP sidecar's `submit_summary` writes pr_title/pr_body/summary
  # here; future tools (submit_test_plan, etc.) write their own
  # keys. Downstream steps read by key. Schema-less on purpose:
  # adding a new artifact type doesn't require a migration, and
  # the contract between producing-step and consuming-step lives
  # in the Steps::* handler code where it belongs.
  serialize :artifacts, coder: JSON

  # JSON-serialized workflow chain declaration used to reconstruct
  # loop nodes after instantiation. Shape:
  #   [{ "type" => "step", "kind" => "prepare" },
  #    { "type" => "loop", "max_iterations" => 5, "steps" => ["implement", "grade"] }]
  serialize :chain_template, coder: JSON

  scope :active, -> { where(state: %w[ queued running ]) }
  scope :epic_wide, -> { where(trigger_kind: EPIC_WIDE_TRIGGER_KINDS) }
  scope :terminal, -> { where(state: %w[ succeeded failed cancelled ]) }
  scope :ordered, -> { order(:created_at) }

  def slug
    "WF-#{id}"
  end

  aasm column: :state, whiny_transitions: false do
    after_all_transitions :record_state_transition!
    state :queued, initial: true
    state :running, :succeeded, :failed, :cancelled

    event :start do
      transitions from: :queued, to: :running, after: -> {
        self.started_at ||= Time.current
        propagate_start_to_job!
      }
    end

    # Each terminal transition stamps finished_at and triggers
    # workspace cleanup. The workspace is per-Workflow (one shallow
    # clone shared across the chain's Steps + Runs), so we tear it
    # down exactly when the Workflow ends — not when each Run
    # finishes (Runs come and go; the chain's Workflow owns the
    # disk space). Trigger-kind-specific concerns (rebase →
    # auto_merge handoff, pr_feedback → mark addressed) live on the
    # `Workflows::*` template class via Workflows::Base#after_success.
    event :succeed do
      transitions from: :running, to: :succeeded, after: -> {
        self.finished_at = Time.current
        cleanup_workspace!
        propagate_succeed_to_job!
        cancel_superseded_retry_workflows!
        dispatch_hook(:after_success)
      }
    end

    # Workspace cleanup is INTENTIONALLY deferred on failure so the
    # operator can use "Retry from failed step" without losing the
    # prior succeeded steps' local-only state (e.g. implement's
    # commit before summarize fails). WorkflowWorkspacePruneJob
    # eventually cleans up via cleanup_workspace! if no retry
    # arrives within the retention window.
    #
    # Exception: infrastructure workflows are never operator-retried;
    # their workspace is cleaned up immediately on failure so they
    # don't accumulate on the PVC between recurring check cycles.
    event :fail do
      transitions from: [ :queued, :running ], to: :failed, after: -> {
        self.finished_at = Time.current
        cancel_orphan_active_runs!
        propagate_fail_to_job!
        dispatch_hook(:after_fail)
        cleanup_workspace! if infrastructure_workflow?
      }
    end

    # Cascading cancel: when the operator cancels a workflow, every
    # active Step (queued/running) and every active Run on those Steps
    # also moves to `cancelled`. Without the cascade, downstream
    # Steps that were waiting for an upstream succeed (which now
    # never comes) sit in `queued` forever — visible to the operator
    # as a Job that "still has queued work" despite the workflow
    # being marked cancelled. There is no dispatcher path that
    # would advance them otherwise.
    event :cancel do
      transitions from: [ :queued, :running ], to: :cancelled, after: -> {
        self.finished_at = Time.current
        cancel_active_descendants!
        propagate_cancel_to_job!
        cleanup_workspace!
        dispatch_hook(:after_cancel)
      }
    end

    # Operator-initiated reopen via "Retry from failed step." Lets
    # the failed Step (and a fresh Run on it) pick up where the
    # workflow left off, reusing the still-on-disk workspace. Guard:
    # only the Job's latest workflow may be reopened — a superseded
    # workflow's workspace was swept by the next workflow's setup.
    event :reopen do
      transitions from: :failed, to: :running, guard: :latest_for_job?,
        after: -> {
          self.finished_at = nil
          propagate_reopen_to_job!
        }
    end
  end

  after_update_commit :schedule_auto_retry!, if: :saved_change_to_state_to_failed?
  after_update_commit :enforce_job_workflow_runaway_limits_on_fail!, if: :saved_change_to_state_to_failed?
  after_create_commit :enforce_job_workflow_runaway_limits_on_create!

  def saved_change_to_state_to_failed?
    saved_change_to_state? && state == "failed"
  end

  def epic_wide?
    Workflow::TriggerKind.epic_wide?(trigger_kind)
  end

  def enforce_job_workflow_runaway_limits_on_create!
    job.enforce_workflow_runaway_limits!(created_workflow: self)
  end

  def enforce_job_workflow_runaway_limits_on_fail!
    job.enforce_workflow_runaway_limits!(failed_workflow: self)
  end

  def job_must_be_open_on_create
    return unless job&.closed?

    errors.add(:job, "is closed")
  end

  # Best-effort workspace teardown. Errors are swallowed (logged at
  # warn level by WorkflowWorkspace.cleanup_for) so a stuck file or
  # missing path can't block a state transition. Writes JobLog entries
  # to the latest run so absence of the log lines signals a missed
  # cleanup.
  def cleanup_workspace!
    if cleanup_blocked_by_active_descendants?
      log_workspace_event("[workspace] cleanup deferred — workflow still has active steps or runs")
      return false
    end

    log_workspace_event("[workspace] cleanup starting")
    WorkflowWorkspace.cleanup_for(self)
    if self.class.where(id: id).pick(:cleaned_up_at).present?
      log_workspace_event("[workspace] cleanup complete")
    else
      log_workspace_event("[workspace] cleanup incomplete — directory may still be on disk; prune job will retry")
    end
    true
  end

  def active_descendants?
    steps.active.exists? || runs.active.exists?
  end

  def live_descendants?
    runs.active.exists? || steps.where(state: "running").exists?
  end

  def cleanup_blocked_by_active_descendants?
    live_descendants?
  end

  # Cancel every still-active Step + Run under this Workflow. Called
  # from the `cancel` event's after-callback above. Cancels Runs first
  # so that the Step's terminal transition observes Runs already
  # cancelled — keeps the per-Run audit trail honest. Idempotent:
  # already-terminal records are skipped (may_cancel? returns false).
  # Cancel any :queued / :running Runs left on
  # this workflow when it transitions to :failed. Unlike
  # cancel_active_descendants! (used by Workflow#cancel), this
  # deliberately does NOT cancel Steps — Workflow#fail preserves the
  # chain shape so "Retry from failed step" can reopen the failed
  # Step and let the dispatcher advance through the still-queued
  # downstream tail. Uses update_columns to bypass Run's
  # cascade_cancel_to_workflow! callback, which would otherwise
  # cancel the Run's Step and break that contract.
  # When a workflow starts, drive the Job into :running (or :landing
  # for auto_merge, but that's handled by LandingQueueProcessor's
  # explicit start_landing! call before instantiating the workflow).
  # Skips for auto_merge so Workflow#start on auto_merge doesn't
  # spuriously try to transition an :approved Job to :running.
  def propagate_start_to_job!
    return if landing_workflow?
    return if infrastructure_workflow?
    return unless job.may_start_running?

    StateTransition.with_source("propagate") do
      job.start_running!
      job.save!
    end
  end

  # When a workflow fails, drive the Job into :failed so the operator
  # can decide between Retry (failed → queued) and Close. Skips for
  # auto_merge — that has its own fail_landing flow that returns
  # :landing → :implemented (RunJob#record_landing_failure!).
  # Skips for coding_handoff/local_mode_handoff because their hooks own
  # state transitions and optional chat notifications.
  #
  # When the failing step raised NoChangesProduced (agent ran correctly
  # but found nothing to do), the Job lands in :no_change_needed rather
  # than :failed so the UI surfaces Close / Give Feedback instead of
  # retry actions.
  def propagate_fail_to_job!
    return if landing_workflow?
    return if coding_handoff_workflow?
    return if local_mode_handoff_workflow?
    return if external_pr_ingest_workflow?
    return if infrastructure_workflow?
    return if newer_active_workflow?

    if no_changes_produced_failure?
      return unless job.may_mark_no_change_needed?

      StateTransition.with_source("propagate") do
        job.mark_no_change_needed!
        job.save!
      end
    else
      return unless job.may_mark_failed?

      StateTransition.with_source("propagate") do
        job.mark_failed!
        job.save!
      end
    end
  end

  def propagate_cancel_to_job!
    return if landing_workflow?
    return if coding_handoff_workflow?
    return if local_mode_handoff_workflow?
    return if infrastructure_workflow?

    # A rebase (or stack_rebase) workflow cancelled before any run started
    # should restore the job to :implemented when the job is stuck in
    # :triaging. This state mismatch occurs after a close+reopen cycle
    # from runaway workflow limits — the reopen event returns the job to
    # :triaging even though it has an open PR. Without this rollback, the
    # merge-state poller dispatches rebase workflows that are immediately
    # cancelled, never advancing the job out of :triaging.
    if %w[rebase stack_rebase].include?(trigger_kind) && runs.none? && job.triaging?
      StateTransition.with_source("propagate") do
        if job.may_restore_after_cancelled_rebase?
          job.restore_after_cancelled_rebase!
          job.save!
        end
      end
      return
    end

    return unless job.running? && job.may_mark_failed?

    StateTransition.with_source("propagate") do
      job.mark_failed!
      job.save!
    end
  end

  def newer_active_workflow?
    return false unless persisted?

    cutoff = created_at || Time.zone.at(0)
    job.workflows
       .active
       .where("created_at > ? OR (created_at = ? AND id > ?)", cutoff, cutoff, id)
       .exists?
  end

  def no_changes_produced_failure?
    runs.where(state: "failed")
        .joins(:run_diagnostic)
        .where(run_diagnostics: { error_class: "Steps::Base::NoChangesProduced" })
        .exists?
  end

  # When a workflow succeeds, the Job's state usually has already
  # been advanced by step-level callbacks (Steps::PrOpen calls
  # mark_implemented! when the initial workflow opens its PR;
  # AutoApprovalRule transitions :running → :implemented → :approved
  # after a successful grade). This is the catch-all for follow-up
  # workflows (pr_comment, ci_failure, retry that pushed to an
  # existing PR) whose chains don't include pr_open: the Job is
  # still :running and needs to return to :implemented now that the
  # follow-up work is done.
  #
  # The :failed escape hatch covers two recovery scenarios:
  #   1. workflow.reopen → workflow.succeed without going through a
  #      fresh propagate_start_to_job (Job sat at :failed the entire
  #      time the reopened workflow ran).
  #   2. A polling-instantiated follow-up workflow ran on a :failed
  #      Job — propagate_start_to_job! no-op'd at workflow.start
  #      because may_start_running? rejects :failed. Without the
  #      escape, the Job would silently stay :failed forever.
  def propagate_succeed_to_job!
    return if landing_workflow?
    return if infrastructure_workflow?
    return if job.implemented? || job.approved? || job.landing? || job.closed?

    StateTransition.with_source("propagate") do
      if job.failed? && job.may_retry_after_failure?
        job.retry_after_failure!
        job.save!
      end

      return unless job.may_mark_implemented?

      job.mark_implemented!
      job.save!
    end
  end

  # Workflow#reopen drives :failed → :running for "Retry from failed
  # step." Keep the parent Job in sync with that live workflow. If the
  # original failure pushed the Job to :failed, retry_after_failure!
  # first returns it to :queued; start_running! then makes the
  # dashboard reflect that work is active again.
  def propagate_reopen_to_job!
    return if landing_workflow?

    StateTransition.with_source("propagate") do
      if job.failed? && job.may_retry_after_failure?
        job.retry_after_failure!
        job.save!
      end

      if job.may_start_running?
        job.start_running!
        job.save!
      end
    end
  end

  def cancel_orphan_active_runs!
    Run.where(step_id: steps.select(:id)).active.find_each do |run|
      run.update_columns(state: "cancelled", finished_at: Time.current)
      RunResourceSummary.refresh_for(run.reload)
    end
  end

  def cancel_active_descendants!
    Step.suppress_cancel_cascade do
      steps.active.find_each do |step|
        step.runs.active.find_each do |run|
          if run.may_cancel?
            run.cancel!
            run.save!
          end
        end
        if step.may_cancel?
          step.cancel!
          step.save!
        end
      end
    end
  end

  def terminal?
    succeeded? || failed? || cancelled?
  end

  def runs
    Run.where(step_id: steps.select(:id)).order(:created_at)
  end

  def total_cost_usd
    runs.sum(:cost_usd)
  end

  def retry_as_new_workflow_available?
    succeeded? || failed?
  end

  # Failed workflows whose disk workspace is still around — the
  # "Retry from failed step" UI gates on this. Once
  # WorkflowWorkspace.cleanup_for has run (either via the
  # succeed/cancel callback above OR via WorkflowWorkspacePruneJob's
  # daily sweep), retry is no longer possible because committed-but-
  # unpushed work from prior succeeded steps is gone.
  #
  # Also requires this to be the Job's latest workflow: once a newer
  # workflow has started, this one's workspace was eagerly swept and
  # "Retry from this step" would base work on stale state anyway.
  def retry_available?
    failed? && cleaned_up_at.nil? && latest_for_job?
  end

  def latest_for_job?
    job.workflows.maximum(:id) == id
  end

  def superseded_by_newer_successful_publication?
    return false unless job.pr_number.present? || job.fork_review_pr_number.present?
    return false unless publication_branch_name.present?

    job.workflows
       .where(state: "succeeded")
       .where("id > ?", id)
       .any? do |candidate|
         publication_branch_name_for(candidate) == publication_branch_name
       end
  end

  def cancel_superseded_retry_workflows!
    return false unless job.pr_number.present? || job.fork_review_pr_number.present?
    return false unless publication_branch_name.present?

    job.workflows
       .active
       .where(trigger_kind: "retry")
       .where("id < ?", id)
       .find_each do |candidate|
         next unless publication_branch_name_for(candidate) == publication_branch_name

         candidate.artifacts = (candidate.artifacts || {}).merge(
           "retry_cancelled_reason" => "superseded",
           "retry_cancelled_at" => Time.current.iso8601,
           "superseded_by_workflow_id" => id
         )
         candidate.cancel! if candidate.may_cancel?
         candidate.save!
       end
    true
  end

  # Read-or-default convenience for artifact access. Nil-safe
  # against a freshly-created Workflow whose `artifacts` column
  # hasn't been touched yet.
  def artifact(key)
    (artifacts || {})[key.to_s]
  end

  # Append-only artifact write. Each producing step calls this
  # once for its outputs. Concurrency-wise the linear chain
  # guarantees one writer at a time, so a read-modify-write is
  # safe without locks.
  def set_artifact!(key, value)
    self.artifacts = (artifacts || {}).merge(key.to_s => value)
    save!
  end

  # Increment the workflow's failure counter and auto-fail the
  # workflow if it crosses the threshold. Per-Workflow scope: a
  # bad CiFailure burst doesn't take down a Job whose Initial was
  # clean.
  def record_run_failure!
    increment!(:failure_count)
    return if state != "running"
    if failure_count >= AppSetting.max_job_failures && may_fail?
      fail!
      save!
    end
  end

  def schedule_auto_retry!
    return unless failed?

    WorkEngine::Reconciler.request(source: "Workflow", job: job, workflow: self)
  end

  def first_step
    steps.find_by(position: 0)
  end

  def current_step
    steps.where(state: %w[ queued running ]).order(:position).first ||
      steps.order(:position).last
  end

  def current_iteration
    steps.active
         .where.not(loop_id: nil)
         .group(:loop_id)
         .maximum(:iteration)
         .values
         .max
  end

  def trigger_kind_humanized
    trigger_kind.tr("_", " ")
  end

  # Landing-flow workflows own their Job's state through their own
  # machinery (LandingQueueProcessor#start_landing!, the merge/land step,
  # and the fail handler that reverts members), so the generic
  # workflow→Job state propagation (propagate_*_to_job!) and the
  # new-workflow auto-retry path must NOT touch the Job for them.
  LANDING_TRIGGER_KINDS = %w[ auto_merge merge_train ].freeze
  INFRASTRUCTURE_TRIGGER_KINDS = %w[ main_grader agent_insight ].freeze

  # Trigger kinds whose workflow template dispatches to the `:runs` queue —
  # the agent-invoking workflows subject to the global agent-concurrency cap
  # (AppSetting.max_concurrent_agent_runs). Derived from the template registry
  # so new trigger kinds are classified automatically. Memoized (registry is
  # static at boot).
  def self.runs_queue_trigger_kinds
    @runs_queue_trigger_kinds ||= Workflow::TriggerKind.values.select do |kind|
      Workflow::TriggerKind.template_for(kind).queue_name == :runs
    end.freeze
  end

  # Per-storage SolidQueue queue that only workers sharing the same durable
  # data root consume (declared in config/queue*.yml). Used to route "Retry
  # from failed step" and post-crash re-enqueues back to a worker that can see
  # the workflow's on-disk workspace. In node-local hostPath deployments this
  # is effectively node affinity; in shared-PVC deployments all workers share
  # one key and can safely share one resume queue.
  def self.resume_queue_name(storage_key)
    "resume-#{storage_key}"
  end

  # Record the worker pod for diagnostics and the durable storage key for
  # resume routing. Cheap update_columns — no callbacks/validation.
  def record_worker_identity!
    host = SyrusVersion.hostname
    storage_key = WorkerStorageIdentity.queue_key
    updates = {}
    updates[:worker_hostname] = host if host.present? && worker_hostname != host
    updates[:worker_storage_key] = storage_key if storage_key.present? && worker_storage_key != storage_key
    return if updates.empty?

    update_columns(updates)
  end
  alias_method :record_worker_hostname!, :record_worker_identity!

  def landing_workflow?
    LANDING_TRIGGER_KINDS.include?(trigger_kind)
  end

  def coding_handoff_workflow?
    trigger_kind == "coding_handoff"
  end

  def local_mode_handoff_workflow?
    trigger_kind == "local_mode_handoff"
  end

  def external_pr_ingest_workflow?
    trigger_kind == "external_pr_ingest"
  end


  # Infrastructure workflows manage their own Job lifecycle via after_success/
  # after_fail hooks. The normal propagate_*_to_job! cascade is skipped so
  # these hidden jobs don't surface in the operator-facing state machine.
  def infrastructure_workflow?
    INFRASTRUCTURE_TRIGGER_KINDS.include?(trigger_kind)
  end


  # Compress json_data (a Hash) with gzip and attach it as the coverage_hit_map blob.
  # Hit map structure: { "app/models/user.rb" => { "1" => 3, "2" => 0, "5" => 1 } }
  # (line number string → hit count; absent line = not executable)
  def attach_coverage_hit_map!(json_data)
    compressed = StringIO.new.tap do |io|
      gz = Zlib::GzipWriter.new(io)
      gz.write(JSON.generate(json_data))
      gz.close
    end.string
    coverage_hit_map.attach(
      io: StringIO.new(compressed),
      filename: "coverage_hit_map.json.gz",
      content_type: "application/gzip"
    )
  end

  # Decompress and parse the attached hit map blob. Returns nil if no attachment.
  def coverage_hit_map_data
    return nil unless coverage_hit_map.attached?

    compressed = coverage_hit_map.download
    JSON.parse(Zlib::GzipReader.new(StringIO.new(compressed)).read)
  end

  # Detach and delete the coverage hit map blob.
  def purge_coverage_hit_map!
    coverage_hit_map.purge
  end


  private

  def publication_branch_name
    artifact("publication_branch").presence || job.branch_name.presence
  end

  def publication_branch_name_for(candidate)
    candidate.artifact("publication_branch").presence || candidate.job.branch_name.presence
  end

  def default_user_from_job
    self.user ||= job&.user
  end

  def user_matches_job
    return if user_id.blank? || job.blank?

    errors.add(:user, "must match the Job owner") if user_id != job.user_id
  end

  def job_for_progress_broadcast
    job
  end

  # Look up the workflow-template class by trigger_kind and invoke
  # its lifecycle hook (after_success / after_fail / after_cancel).
  # Each `Workflows::*` class declares only the hooks it cares
  # about; the rest default to no-ops via Workflows::Base. Hooks
  # are best-effort — exceptions are caught and logged so a
  # downstream failure (queue blip, race) doesn't roll back the
  # workflow's already-committed state transition.
  def dispatch_hook(name)
    klass = Workflows.for(trigger_kind: trigger_kind)
    klass.public_send(name, self)
  rescue ArgumentError
    # Unknown trigger_kind — no template, no hook. Old workflows
    # whose trigger_kind has since been retired land here; that's fine.
    nil
  rescue StandardError => e
    Rails.logger.warn("[Workflow##{id}] #{name} hook raised: #{e.class}: #{e.message}")
  end

  # Write a JobLog entry on the latest run so cleanup activity is
  # visible in the transcript UI. Best-effort — failure here must
  # not block cleanup or state transitions.
  def log_workspace_event(message)
    run = Run.where(step_id: steps.select(:id)).order(created_at: :desc).first
    return unless run
    JobLog.append!(run: run, chunk: message, kind: "system")
  rescue StandardError
    # Logging is informational; never let it interfere with cleanup.
  end
end
