module Workflows
  # Value object for a repeatable section in a workflow chain template.
  # Workflows::Base materializes only iteration 1 at instantiation time;
  # later dispatcher work can read Workflow#chain_template to append more.
  #
  # `review_first:` models an agent/reviewer pair (e.g. implement +
  # adversarial_review) whose iterations are asymmetric rather than a
  # uniform repeat of `steps`:
  #
  #   iteration 1            — [ review_step ] only (reviews work that
  #                             already happened outside this loop)
  #   iterations 2..(N - 1)   — [ agent_step, review_step ]
  #   iteration N (max, last) — [ agent_step ] only (a final repair attempt
  #                             with no review left in the budget to act on)
  #
  # StepDispatcher#enqueue_next_loop_iteration! drops the trailing review
  # step when materializing the final iteration; `steps` always stores the
  # full [agent_step, review_step] pair so `loop_step_kinds` and friends can
  # keep treating it as the canonical shape.
  class Loop
    attr_reader :max_iterations, :steps, :review_first

    def initialize(steps:, max_iterations: nil, review_first: false)
      steps_array = Array(steps)
      raise ArgumentError, "loop steps required" if steps_array.empty?
      if review_first && steps_array.size != 2
        raise ArgumentError, "review_first loop requires exactly 2 steps: [agent_step, review_step]"
      end

      @nested = steps_array.any? { |s| s.is_a?(Workflows::Loop) || s.is_a?(Workflows::RetryUntil) }
      @steps = (@nested ? steps_array : steps_array.map(&:to_s)).freeze
      @max_iterations = max_iterations
      @review_first = review_first
    end

    def loop? = true

    def review_first? = review_first

    # Steps materialized for iteration 1 at instantiation time. A plain
    # loop repeats the full pair; a review_first loop starts with just the
    # review step, since the agent step it's reviewing already ran outside
    # the loop.
    def step_kinds
      review_first? ? [ steps.last.to_s ] : steps.map(&:to_s)
    end

    def to_chain_template
      {
        "type" => "loop",
        "max_iterations" => max_iterations,
        "steps" => steps.map(&:to_s),
        "review_first" => review_first?
      }
    end
  end
end
