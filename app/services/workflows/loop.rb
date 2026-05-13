module Workflows
  # Value object for a repeatable section in a workflow chain template.
  # Workflows::Base materializes only iteration 1 at instantiation time;
  # later dispatcher work can read Workflow#chain_template to append more.
  class Loop
    attr_reader :max_iterations, :steps

    def initialize(steps:, max_iterations: nil)
      raise ArgumentError, "loop steps required" if Array(steps).empty?

      @steps = Array(steps).freeze
      @max_iterations = max_iterations
    end

    def loop? = true

    def step_kinds
      steps.map(&:to_s)
    end

    def to_chain_template
      {
        "type" => "loop",
        "max_iterations" => max_iterations,
        "steps" => step_kinds
      }
    end
  end
end
