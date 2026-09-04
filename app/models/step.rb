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

  # workflow-engine-v3 A5: the graph edges. `next_step_id` still orders the
  # chain; these say what a Step is *waiting for*, which is what turns "find
  # next" into a ready-set query and lets fan-in be an edge rather than a
  # sentinel plus a per-kind rule.
  #
  # Empty means "just my predecessor", so an existing Step with no edges
  # behaves exactly as it did.
  # MySQL 8 rejects defaults on JSON columns, so the empty list is seeded here
  # rather than by the schema (see CLAUDE.md).
  after_initialize :seed_depends_on_ids, if: :new_record?

  def depends_on_step_ids = Array(depends_on_ids).map(&:to_i)

  def depends_on_steps
    return [] if depends_on_step_ids.empty?

    workflow.steps.where(id: depends_on_step_ids).to_a
  end

  # A Step is ready when everything it waits for has finished, whatever the
  # outcome -- a failed dependency is still a settled one, and what happens
  # next is the remediation table's business, not the graph's.
  def dependencies_settled?
    return previous_step.nil? || previous_step.terminal? if depends_on_step_ids.empty?

    depends_on_steps.all?(&:terminal?)
  end

  def seed_depends_on_ids
    self.depends_on_ids = [] if depends_on_ids.nil?
  end

  # See Workflow#trigger_kind: resolved per validation so plugin-contributed
  # step kinds are honoured.
  validates :kind, presence: true, inclusion: { in: ->(_) { Step::Kind.values } }
  validates :position, presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  ACTIVE_STATES = %w[ queued running ].freeze
  TERMINAL_STATES = %w[ succeeded failed cancelled skipped ].freeze

  # MySQL 8 rejects defaults on JSON columns, so seed `{}` on new
  # records via after_initialize instead of a column default. Existing
  # rows were backfilled by the AddDetailsToSteps migration.
  # (Native JSON column handles encode/decode — no explicit
  # serialize: needed.)
  after_initialize :default_details, if: :new_record?

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :terminal, -> { where(state: TERMINAL_STATES) }

  # When a Step transitions to :cancelled, `cancel_workflow_chain!`
  # normally cascades the cancellation to downstream queued steps
  # and (if the workflow is left with no active work) cancels the
  # workflow itself. That cascade is what we want for "this step
  # was the current chain — the workflow is dead" cases.
  #
  # Historical "skip one future step" callsites used cancelled with the
  # cascade suppressed. New benign no-op paths should use :skipped instead;
  # this suppression remains for real cancellation propagation that must not
  # fan out further.
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
    state :running, :succeeded, :failed, :cancelled, :skipped

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

    event :skip do
      transitions from: [ :queued, :running ], to: :skipped, after: -> { self.finished_at = Time.current }
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

  def slug
    "STEP-#{id || 'new'}"
  end

  def terminal?
    TERMINAL_STATES.include?(state)
  end

  def state_projection(runs: nil)
    Steps::StateProjection.for(self, runs: runs)
  end

  def visible_state(runs: nil)
    state_projection(runs: runs).visible_state
  end

  def skip_with_reason!(reason)
    return false unless may_skip?

    self.details = details.to_h.merge("skipped" => true, "skip_reason" => reason)
    skip!
    save!
  end

  after_update_commit :advance_next_step!, if: :saved_change_to_state_to_succeeded?
  after_update_commit :apply_auto_approval_rule!, if: :saved_change_to_succeeded_grade?
  after_update_commit :fail_workflow!, if: :saved_change_to_state_to_failed?
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
    Steps::LifecyclePropagation.succeeded!(self)
  end

  def apply_auto_approval_rule!
    Steps::LifecyclePropagation.succeeded_grade!(self)
  end

  def fail_workflow!
    Steps::LifecyclePropagation.failed!(self)
  end

  def cancel_workflow_chain!
    Steps::LifecyclePropagation.cancelled!(self)
  end

  # The most recently created Run on this Step — i.e. the latest
  # attempt. Failed retries become previous Runs; the latest Run
  # is what reflects the step's current state.
  def latest_run
    runs.order(:created_at).last
  end

  # The session_id from the latest succeeded agentic Run upstream,
  # used by this Step's Run as `parent_session_id` so the next
  # agent call resumes the prior conversation. Walks backwards
  # through `previous_step` ancestors, skipping non-agentic steps
  # like grade/prepare/pr_open which legitimately have no session
  # — without the walk, Summarize after `loop(implement → grade)`
  # would see grade as its immediate predecessor, find no session
  # there, and spawn the agent with no `--resume` despite the
  # Summarize prompt promising "your previous conversation".
  # Bails out (returns nil) the moment it hits a non-succeeded
  # ancestor: the chain hasn't progressed past that step, so any
  # session further back is stale or unreachable.
  def upstream_session_id
    cursor = previous_step

    while cursor
      return nil unless cursor.state == "succeeded"

      session_id = cursor.latest_run&.provider_session&.session_id
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
