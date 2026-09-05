module Workflows
  # Value object for a repeatable review section in a workflow chain
  # template. Workflows::Base materializes only iteration 1 at
  # instantiation time; later dispatcher work can read Workflow#chain_template
  # to append more.
  #
  # Every Loop models an agent/reviewer pair (e.g. implement +
  # adversarial_review) whose iterations are asymmetric rather than a
  # uniform repeat of `steps` -- the agent step it reviews always ran
  # before this loop (either as a bare leading step, or as the previous
  # loop's own last repair), so iteration 1 only needs to consult the
  # reviewer:
  #
  #   iteration 1            — [ review_step ] only (reviews work that
  #                             already happened outside this loop)
  #   iterations 2..N        — [ agent_step, review_step ] (a repair
  #                             reacting to the prior needs_work verdict,
  #                             paired with another review) -- inserted
  #                             unconditionally on every needs_work verdict
  #   iteration N (final)    — [ agent_step ] only once review N's verdict
  #                             is needs_work and no review budget remains:
  #                             one last repair attempt with no further
  #                             review to act on it
  #
  # StepDispatcher#enqueue_next_loop_iteration! drops the trailing review
  # step when materializing that final iteration; `steps` always stores the
  # full [agent_step, review_step] pair so `loop_step_kinds` and friends can
  # keep treating it as the canonical shape.
  class Loop
    attr_reader :max_iterations, :steps

    def initialize(steps:, max_iterations: nil)
      steps_array = Array(steps)
      raise ArgumentError, "loop steps required" if steps_array.empty?
      raise ArgumentError, "loop requires exactly 2 steps: [agent_step, review_step]" if steps_array.size != 2

      @nested = steps_array.any? { |s| s.is_a?(Workflows::Loop) || s.is_a?(Workflows::RetryUntil) }
      @steps = (@nested ? steps_array : steps_array.map(&:to_s)).freeze
      @max_iterations = max_iterations
    end

    def loop? = true

    # Steps materialized for iteration 1 at instantiation time: just the
    # review step, since the agent step it reviews always ran before this
    # loop.
    def step_kinds
      [ steps.last.to_s ]
    end

    def to_chain_template
      {
        "type" => "loop",
        "max_iterations" => max_iterations,
        "steps" => steps.map(&:to_s)
      }
    end
  end
end
