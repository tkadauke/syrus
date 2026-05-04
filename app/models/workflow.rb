class Workflow < ApplicationRecord
  include AASM

  # Trigger kinds the v1 templates handle. The first six map
  # 1:1 to today's Run.trigger_kind values; once the migration
  # off Run.trigger_kind lands, this is the canonical list.
  TRIGGER_KINDS = %w[ initial pr_comment ci_failure rebase replay manual resume ].freeze

  belongs_to :job
  has_many :steps, -> { order(:position) }, dependent: :destroy

  validates :trigger_kind, presence: true, inclusion: { in: TRIGGER_KINDS }

  # Free-form bag of artifacts produced during this workflow. The
  # MCP sidecar's `submit_summary` writes pr_title/pr_body/summary
  # here; future tools (submit_test_plan, etc.) write their own
  # keys. Downstream steps read by key. Schema-less on purpose:
  # adding a new artifact type doesn't require a migration, and
  # the contract between producing-step and consuming-step lives
  # in the Steps::* handler code where it belongs.
  serialize :artifacts, coder: JSON

  scope :active, -> { where(state: %w[ queued running ]) }
  scope :terminal, -> { where(state: %w[ succeeded failed cancelled ]) }
  scope :ordered, -> { order(:created_at) }

  aasm column: :state, whiny_transitions: false do
    state :queued, initial: true
    state :running, :succeeded, :failed, :cancelled

    event :start do
      transitions from: :queued, to: :running, after: -> { self.started_at ||= Time.current }
    end

    # Each terminal transition stamps finished_at and triggers
    # workspace cleanup. The workspace is per-Workflow (one shallow
    # clone shared across the chain's Steps + Runs), so we tear it
    # down exactly when the Workflow ends — not when each Run
    # finishes (Runs come and go; the chain's Workflow owns the
    # disk space).
    event :succeed do
      transitions from: :running, to: :succeeded, after: -> {
        self.finished_at = Time.current
        cleanup_workspace!
      }
    end

    # Workspace cleanup is INTENTIONALLY deferred on failure so the
    # operator can use "Retry from failed step" without losing the
    # prior succeeded steps' local-only state (e.g. implement's
    # commit before summarize fails). WorkflowWorkspacePruneJob
    # eventually cleans up via cleanup_workspace! if no retry
    # arrives within the retention window.
    event :fail do
      transitions from: [ :queued, :running ], to: :failed, after: -> {
        self.finished_at = Time.current
      }
    end

    event :cancel do
      transitions from: [ :queued, :running ], to: :cancelled, after: -> {
        self.finished_at = Time.current
        cleanup_workspace!
      }
    end

    # Operator-initiated reopen via "Retry from failed step." Lets
    # the failed Step (and a fresh Run on it) pick up where the
    # workflow left off, reusing the still-on-disk workspace.
    event :reopen do
      transitions from: :failed, to: :running, after: -> {
        self.finished_at = nil
      }
    end
  end

  # Best-effort workspace teardown. Errors are swallowed (logged at
  # warn level by WorkflowWorkspace.cleanup_for) so a stuck file or
  # missing path can't block a state transition. Writes JobLog entries
  # to the latest run so absence of the log lines signals a missed
  # cleanup.
  def cleanup_workspace!
    log_workspace_event("[workspace] cleanup starting")
    WorkflowWorkspace.cleanup_for(self)
    if self.class.where(id: id).pick(:cleaned_up_at).present?
      log_workspace_event("[workspace] cleanup complete")
    else
      log_workspace_event("[workspace] cleanup incomplete — directory may still be on disk; prune job will retry")
    end
  end

  def terminal?
    succeeded? || failed? || cancelled?
  end

  # Failed workflows whose disk workspace is still around — the
  # "Retry from failed step" UI gates on this. Once
  # WorkflowWorkspace.cleanup_for has run (either via the
  # succeed/cancel callback above OR via WorkflowWorkspacePruneJob's
  # daily sweep), retry is no longer possible because committed-but-
  # unpushed work from prior succeeded steps is gone.
  def retry_available?
    failed? && cleaned_up_at.nil?
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

  def first_step
    steps.find_by(position: 0)
  end

  def current_step
    steps.where(state: %w[ queued running ]).order(:position).first ||
      steps.order(:position).last
  end

  def trigger_kind_humanized
    trigger_kind.tr("_", " ")
  end

  private

  # Write a JobLog entry on the latest run so cleanup activity is
  # visible in the transcript UI. Best-effort — failure here must
  # not block cleanup or state transitions.
  def log_workspace_event(message)
    run = Run.where(step_id: steps.select(:id)).order(created_at: :desc).first
    return unless run
    seq = (run.job_logs.maximum(:sequence) || -1) + 1
    run.job_logs.create!(chunk: message, sequence: seq, kind: "system")
  rescue StandardError
    # Logging is informational; never let it interfere with cleanup.
  end
end
