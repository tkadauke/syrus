class Run < ApplicationRecord
  include AASM

  TRIGGER_KINDS = %w[ initial pr_comment ci_failure retry manual rebase auto_merge resume local_dev ].freeze

  belongs_to :job
  # Step is optional during the migration window: existing Runs
  # (and the existing direct-create paths in Job#after_create_commit
  # and the polling jobs) still link to Job. Once those code paths
  # have moved to instantiate Workflows + Steps, a follow-up migration
  # backfills runs.step_id on every existing Run and flips the
  # belongs_to to required.
  belongs_to :step, optional: true
  has_many :job_logs, -> { order(:sequence) }, dependent: :destroy
  has_many :run_health_snapshots, -> { order(:created_at) }, dependent: :destroy
  has_one :claude_session, dependent: :destroy
  has_one :run_diagnostic, dependent: :destroy

  # Convenience walk up to Workflow when step is set.
  def workflow
    step&.workflow
  end

  validates :trigger_kind, presence: true, inclusion: { in: TRIGGER_KINDS }
  validates :agent_provider, presence: true, inclusion: { in: User::AGENT_PROVIDERS }

  # Backstop for genuine agent hangs (claude alive but making no
  # progress). Rare in practice — claude almost always streams a chunk
  # at least every few minutes. The reaper's PRIMARY signal is the
  # SolidQueue claim being gone (worker died → claim released by SQ
  # supervisor); this threshold only triggers when the claim is still
  # alive but the agent itself stopped emitting transcript output.
  # 30 min comfortably covers normal long-tool-call gaps (large file
  # reads, broad greps, multi-file edits).
  STALE_HEARTBEAT_THRESHOLD = 30.minutes

  scope :active, -> { where(state: %w[ queued running ]) }
  scope :terminal, -> { where(state: %w[ succeeded failed cancelled ]) }
  scope :ordered, -> { order(:created_at) }
  scope :stale, -> {
    t = STALE_HEARTBEAT_THRESHOLD.ago
    where(state: "running")
      .where("last_heartbeat_at < :t OR (last_heartbeat_at IS NULL AND started_at < :t)", t: t)
  }

  aasm column: :state, whiny_transitions: false do
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
  after_update_commit :clear_transcript_on_success!,
                       if: :saved_change_to_state_to_succeeded?

  def saved_change_to_state_to_cancelled?
    saved_change_to_state? && state == "cancelled"
  end

  def saved_change_to_state_to_succeeded?
    saved_change_to_state? && state == "succeeded"
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

  # State changes (queued → running → succeeded/failed/cancelled) and
  # field updates (agent_turns, agent_outcome, agent_diff) all need to
  # show up on the Job's show page without requiring the operator to
  # refresh. Broadcasting refreshes to the parent Job's stream means
  # "tell anyone watching this Job to morph itself".
  #
  # The fallback `[ "dead_run", run.id ]` covers the cascade-destroy
  # path: when the parent Job is destroyed, run.job returns nil, but
  # turbo-rails' default `send(stream)` fallback would then try to
  # send the lambda itself as a method name (TypeError). Returning
  # a stable, non-nil stream identifier makes the broadcast a no-op
  # in that case (no subscriber on that stream).
  broadcasts_refreshes_to ->(run) { run.job || [ "dead_run", run.id ] }
  broadcasts_refreshes_to ->(run) {
    run.job ? [ run.job.user, "jobs" ] : [ "dead_run", run.id, "jobs" ]
  }

  def self.average_duration_for(trigger_kind)
    # `where.not(a: nil, b: nil)` compiles to `NOT (a IS NULL AND b IS NULL)`
    # — it only excludes rows where BOTH are nil, not where either is.
    # Rows with one nil slip through and break the subtraction below.
    # Chain the two excludes so we filter rows where EITHER is nil.
    completed = terminal.where(trigger_kind: trigger_kind)
                        .where.not(started_at: nil)
                        .where.not(finished_at: nil)
    return nil if completed.empty?
    total = completed.sum { |r| r.finished_at - r.started_at }
    (total / completed.size).to_i
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

  # Resume Runs continue a Claude Code session whose worker died
  # mid-flight. RunJob restores the prior session's JSONL to disk
  # before invoking claude with --resume, and uses Prompts::Resume
  # as the new prompt so claude knows what just happened.
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

  private

  def clear_transcript_on_success!
    claude_session&.update_column(:transcript_jsonl, nil)
  end

  def enqueue_run_job
    return if terminal?
    # When a RunJob is currently driving the chain inline, the next
    # Step's Run was just created here (by StepDispatcher) but should
    # NOT bounce through SolidQueue — the in-flight RunJob will pick
    # it up directly via its loop. Skipping the perform_later avoids
    # a queue round-trip that would land at the back of FIFO and
    # spread one Workflow across multiple worker pickups.
    return if Thread.current[:syrus_in_run_job]
    RunJob.set(priority: job.solid_queue_priority).perform_later(id)
  end
end
