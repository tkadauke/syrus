# Durable audit record for one dispatch of a Story 11
# (docs/plans/delivery-tracks-and-promotion.md) named ref-movement action —
# `send_job_upstream` or `submit_branch_upstream` today. Every dispatch
# attempt gets a row, whether it actually launched a Workflow or was
# blocked by config/eligibility, so operators can see who requested a ref
# movement, what source/target refs were resolved, whether the target was
# inferred from `Repository#upstream_repository` rather than explicitly
# given, and what validation policy (mode/grade_phases) applied — per the
# plan's `RefMovementAction.dispatch!` sketch.
#
# `RefMovementActions::Base.for(action_name)` holds the actual per-action
# dispatch logic (a class per action, not a `case action_name` chain — see
# CLAUDE.md's enum-driven-behavior convention); this model is the record,
# not the dispatcher.
class RefMovementAction < ApplicationRecord
  STATES = %w[dispatched blocked].freeze

  belongs_to :repository
  belongs_to :job, optional: true
  belongs_to :requested_by_user, class_name: "User"
  belongs_to :target_repository, class_name: "Repository", optional: true
  belongs_to :workflow, optional: true

  validates :action_name, presence: true
  validates :state, presence: true, inclusion: { in: STATES }

  after_initialize :default_grade_phases, if: :new_record?

  def self.dispatch!(repository:, actor:, action:, source: nil, target: nil)
    RefMovementActions::Base.for(action).dispatch!(
      repository: repository,
      actor: actor,
      action: action.to_s,
      source: source,
      target: target
    )
  end

  def dispatched?
    state == "dispatched"
  end

  def blocked?
    state == "blocked"
  end

  private

  def default_grade_phases
    self.grade_phases ||= []
  end
end
