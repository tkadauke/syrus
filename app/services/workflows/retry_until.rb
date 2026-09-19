module Workflows
  # Value object for a bounded "repair until check passes" section in a
  # workflow chain template. Workflows::Base materializes only the first
  # iteration at instantiation time; StepDispatcher appends later repair +
  # check iterations when the check terminal Step fails.
  class RetryUntil
    attr_reader :repair_steps, :check_steps, :max_iterations, :repair_first

    def initialize(repair:, check:, max_iterations: nil, repair_first: true)
      @repair_steps = normalize_steps(repair, "repair")
      @check_steps = normalize_steps(check, "check")
      @max_iterations = max_iterations
      @repair_first = repair_first
    end

    def retry_until? = true

    def repair_first? = repair_first

    def step_kinds
      repair_first? ? iteration_step_kinds : check_steps
    end

    def iteration_step_kinds
      repair_steps + check_steps
    end

    def to_chain_template
      {
        "type" => "retry_until",
        "max_iterations" => max_iterations,
        "repair" => repair_steps,
        "check" => check_steps,
        "repair_first" => repair_first?
      }
    end

    private

    def normalize_steps(steps, label)
      steps_array = Array(steps)
      raise ArgumentError, "retry_until #{label} steps required" if steps_array.empty?

      if steps_array.any? { |step| step.respond_to?(:to_chain_template) }
        raise ArgumentError, "nested workflow control nodes are not supported"
      end

      steps_array.map(&:to_s).freeze
    end
  end
end
