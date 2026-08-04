class Step < ApplicationRecord
  include AASM
  include RecordsStateTransitions
  include BroadcastsJobProgress

  KINDS = Step::Kind.values
  AGENTIC_KINDS = Step::Kind.agentic_values

  belongs_to :workflow
  belongs_to :next_step, class_name: "Step", optional: true
  has_one :previous_step, class_name: "Step", foreign_key: :next_step_id
  # Now that backfill (commit 8) has populated runs.step_id for
  # every existing Run, Step is the canonical owner of Runs. Job's
  # has_many :runs cascade was removed in the same change — the
  # cascade path is Job → Workflow → Step → Run.
  has_many :runs, -> { order(:created_at) }, dependent: :destroy
  has_many :run_resource_summaries, dependent: :destroy

  validates :kind, presence: true, inclusion: { in: KINDS }
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # MySQL 8 rejects defaults on JSON columns, so seed `{}` on new
  # records via after_initialize instead of a column default. Existing
  # rows were backfilled by the AddDetailsToSteps migration.
  # (Native JSON column handles encode/decode — no explicit
  # serialize: needed.)
  after_initialize :default_details, if: :new_record?

  scope :active, -> { where(state: %w[ queued running ]) }
  scope :terminal, -> { where(state: %w[ succeeded failed cancelled ]) }

  # When a Step transitions to :cancelled, `cancel_workflow_chain!`
  # normally cascades the cancellation to downstream queued steps
  # and (if the workflow is left with no active work) cancels the
  # workflow itself. That cascade is what we want for "this step
  # was the current chain — the workflow is dead" cases.
  #
  # But there's a legitimate inverse pattern: a still-running
  # upstream step intentionally cancels a single FUTURE step it
  # knows it can skip (Steps::AutoRebase cancelling agent_rebase
  # after a clean deterministic rebase; the dispatcher's
  # cancel_post_loop_steps! before failing the workflow with a
  # reason). In those cases the auto-cascade would over-reach and
  # kill the rest of the chain. Wrap the explicit cancel call in
  # `Step.suppress_cancel_cascade { ... }` to opt out.
  def self.suppress_cancel_cascade
    prior = Thread.current[:syrus_step_suppress_cancel_cascade]
    Thread.current[:syrus_step_suppress_cancel_cascade] = true
    yield
  ensure
    Thread.current[:syrus_step_suppress_cancel_cascade] = prior
  end

  aasm column: :state, whiny_transitions: false do
    after_all_transitions :record_state_transition!
    state :queued, initial: true
    state :running, :succeeded, :failed, :cancelled

    event :start do
      transitions from: :queued, to: :running, after: -> { self.started_at ||= Time.current }
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

    # Reopen a failed Step so a new Run can be created on it. Used
    # by the retry-step command. Resets the timing fields — the
    # next perform_step's start! callback will repopulate started_at.
    # The failed prior Run stays on the Step as historical record.
    event :reopen do
      transitions from: :failed, to: :queued, after: -> {
        self.started_at = nil
        self.finished_at = nil
      }
    end
  end

  def agentic?
    AGENTIC_KINDS.include?(kind)
  end

  def terminal?
    succeeded? || failed? || cancelled?
  end

  # When a Step succeeds, hand off to the dispatcher to start the
  # next one (if any). Linear chain — `next_step` is at most one.
  # The dispatcher is what creates the Run on the next Step; this
  # callback just signals "I'm done; move along".
  after_update_commit :advance_next_step!, if: :saved_change_to_state_to_succeeded?
  after_update_commit :apply_auto_approval_rule!, if: :saved_change_to_succeeded_grade?

  # When a Step fails, the linear chain can't advance: v1 has no
  # intra-workflow retry, so the workflow itself is dead. Mark
  # the Workflow failed (which fires its own cleanup callbacks).
  after_update_commit :fail_workflow!, if: :saved_change_to_state_to_failed?

  # When a Step is cancelled, anything queued behind it in the
  # chain is orphaned: the dispatcher only advances on succeed,
  # so the queued tail will never run. Cascade the cancel to
  # downstream queued steps, then (if the workflow has no active
  # work left) cancel the workflow itself so workspace cleanup +
  # after_cancel hooks fire. Legitimate "skip one future step"
  # callsites wrap their cancel in Step.suppress_cancel_cascade
  # to opt out — see the class method's comment.
  after_update_commit :cancel_workflow_chain!, if: :saved_change_to_state_to_cancelled?

  def saved_change_to_state_to_succeeded?
    saved_change_to_state? && state == "succeeded"
  end

  def saved_change_to_state_to_failed?
    saved_change_to_state? && state == "failed"
  end

  def saved_change_to_state_to_cancelled?
    saved_change_to_state? && state == "cancelled"
  end

  def saved_change_to_succeeded_grade?
    saved_change_to_state_to_succeeded? &&
      Step::Kind.fetch(kind).triggers_auto_approval
  rescue ArgumentError
    false
  end

  def advance_next_step!
    StepDispatcher.advance_from(self)
  end

  def apply_auto_approval_rule!
    AutoApprovalRule.for(workflow.job).apply_after_grader_success!(self)
  end

  def fail_workflow!
    StepDispatcher.fail_from(self)
  end

  def cancel_workflow_chain!
    return if Thread.current[:syrus_step_suppress_cancel_cascade]

    Step.suppress_cancel_cascade { cancel_downstream_queued_steps! }
    cancel_workflow_if_idle!
  end

  def cancel_downstream_queued_steps!
    cursor = next_step
    while cursor
      if cursor.may_cancel?
        cursor.cancel!
        cursor.save!
      end
      cursor = cursor.next_step
    end
  end

  def cancel_workflow_if_idle!
    wf = workflow
    return unless wf.may_cancel?
    return if wf.active_descendants?

    wf.cancel!
    wf.save!
  end

  # The most recently created Run on this Step — i.e. the latest
  # attempt. Failed retries become previous Runs; the latest Run
  # is what reflects the step's current state.
  def latest_run
    runs.order(:created_at).last
  end

  # The session_id from the latest succeeded upstream Run, used by
  # this Step's Run as `parent_session_id` so the next agent call
  # resumes the prior conversation. Non-agentic steps (e.g. grade)
  # are valid upstream steps but do not create sessions, so walk
  # backward until an agentic session is found. Nil when there's no
  # upstream session (first step in workflow, unsucceeded upstream
  # step, or cross-workflow trigger).
  def upstream_session_id
    cursor = previous_step

    while cursor
      return nil unless cursor.state == "succeeded"

      session_id = cursor.latest_run&.claude_session&.session_id
      return session_id if session_id.present?

      cursor = cursor.previous_step
    end

    nil
  end

  private

  def job_for_progress_broadcast
    workflow&.job
  end

  def default_details
    self.details ||= {}
  end
end
