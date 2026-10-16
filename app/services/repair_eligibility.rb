class RepairEligibility
  STATUSES = %w[eligible noop rejected].freeze

  attr_reader :status, :operation, :target_state, :blocking_preconditions,
    :expected_mutations, :affected_ids, :facts

  def initialize(status:, operation:, target_state: nil, blocking_preconditions: [],
    expected_mutations: {}, affected_ids: {}, facts: {})
    raise ArgumentError, "invalid repair eligibility status: #{status}" unless status.to_s.in?(STATUSES)

    @status = status.to_s
    @operation = operation.to_s
    @target_state = target_state
    @blocking_preconditions = Array(blocking_preconditions)
    @expected_mutations = expected_mutations
    @affected_ids = affected_ids
    @facts = facts
  end

  def eligible? = status == "eligible"
  def noop? = status == "noop"
  def rejected? = status == "rejected"

  def ensure_eligible!
    return self if eligible?

    detail = blocking_preconditions.presence&.join("; ") || "no mutations are applicable"
    raise Ineligible, "#{operation} is #{status}: #{detail}"
  end

  def as_json(*)
    {
      status: status,
      operation: operation,
      target_state: target_state,
      blocking_preconditions: blocking_preconditions,
      expected_mutations: expected_mutations,
      affected_ids: affected_ids,
      facts: facts
    }
  end

  class Ineligible < ArgumentError; end
end
