# Which rungs a workflow climbs before it costs a person anything
# (workflow-engine-v3, "The ladder").
#
#   0 · deterministic adjudication  free      Adjudicators
#   1 · deterministic repair        cheap     format/generate, auto_rebase, backoff
#   2 · agentic repair              one turn  landing_fix, the implement loop
#   3 · agentic adjudication        one turn  Adjudicators::AgenticGraderReview
#   4 · human decision              expensive Decisions::Escalator
#
# The ladder differs per work definition because the cost of being wrong
# differs. A stalled landing is the expensive failure, so auto_merge spends a
# turn on judgment before giving up. A rebase never escalates at all -- the
# next merge-state poll retries anyway, and waking someone for it is worse
# than the failure.
#
# Rung 3 is deliberately enabled for one definition to begin with. It costs a
# turn every time it runs, and the plan's own instruction is to let the
# escalations-per-landing metric decide whether to widen it.
module AttentionLadder
  RUNGS = %i[deterministic deterministic_repair agentic_repair adjudicate escalate].freeze

  LADDERS = {
    # Never gives up silently: a stalled landing is the expensive failure.
    "auto_merge" => %i[deterministic adjudicate agentic_repair escalate],
    "merge_train" => %i[deterministic adjudicate agentic_repair escalate],
    # Never escalates; the next merge-state poll retries anyway.
    "rebase" => %i[deterministic agentic_repair],
    "stack_rebase" => %i[deterministic agentic_repair],
    # Broken main blocks everything.
    "main_branch_repair" => %i[deterministic agentic_repair escalate],
    # Failure is normal and cheap here.
    "initial" => %i[deterministic agentic_repair],
    "retry" => %i[deterministic agentic_repair]
  }.freeze

  DEFAULT = %i[deterministic agentic_repair escalate].freeze

  def self.for(trigger_kind)
    LADDERS.fetch(trigger_kind.to_s, DEFAULT)
  end

  def self.includes?(trigger_kind, rung)
    self.for(trigger_kind).include?(rung.to_sym)
  end

  # Whether this workflow is allowed to spend an agent turn on judgment.
  def self.adjudicates?(trigger_kind) = includes?(trigger_kind, :adjudicate)

  # Whether a failure here is worth waking someone for.
  def self.escalates?(trigger_kind) = includes?(trigger_kind, :escalate)
end
