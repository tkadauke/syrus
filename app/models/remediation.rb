# What to do about a Problem (workflow-engine-v3 primitive B).
#
# One closed action set, so that in-flight handling and out-of-band
# reconciliation stop being separate implementations of the same decision.
# Today the same question is answered five different ways -- `fail_policy`,
# `Workflows::Try#on_failure`, `RetryUntil`, `WorkUnits::RetryPolicies`, and
# the RepairExecutor's actions -- picked by convention rather than by rule.
#
# A remediation is an action plus whatever that action needs (`repair_with`
# names a step kind, `defer` names a time). `source` records which tier of the
# resolution rule answered, which is what makes a surprising decision
# traceable rather than archaeological.
class Remediation
  # The closed set. Anything outside it is a bug, not a new case.
  ACTIONS = %i[
    retry_step resume_step repair_with insert branch skip advance
    restart_workflow rebuild_unit defer preempt escalate fail
  ].freeze

  # Where a remediation came from, in precedence order. Recorded so an
  # unexpected action can be traced to the tier that produced it.
  SOURCES = %i[step_override template_override work_definition problem_default].freeze

  attr_reader :action, :args, :source

  def self.[](action, source:, **args)
    new(action, source: source, **args)
  end

  def initialize(action, source:, **args)
    @action = action.to_sym
    raise ArgumentError, "unknown remediation action=#{action.inspect}" unless ACTIONS.include?(@action)
    raise ArgumentError, "unknown remediation source=#{source.inspect}" unless SOURCES.include?(source.to_sym)

    @source = source.to_sym
    @args = args.freeze
    freeze
  end

  ACTIONS.each do |name|
    define_method("#{name}?") { action == name }
  end

  # True when the engine can carry this out on its own. `escalate` and `fail`
  # are the two that end in a human.
  def automatic? = !%i[escalate fail].include?(action)

  def ==(other)
    other.is_a?(Remediation) && other.action == action && other.args == args
  end
  alias eql? ==

  def hash = [ action, args ].hash
  def to_s = action.to_s
  def inspect = "#<Remediation #{action}#{args.any? ? " #{args.inspect}" : ""} via #{source}>"
end
