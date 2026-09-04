module Workflows
  # Waits for every Step a fan-out produced (workflow-engine-v3 primitive E).
  #
  # The counterpart to ForEachMember, and now a thin one: since A5 gave Steps
  # real dependency edges, a barrier is just a Step that depends on all of
  # them. It needs no sentinel and no per-kind rule -- it is simply not ready
  # while any member Step is still running, which is the same mechanism
  # grader_collect uses.
  class Barrier
    attr_reader :step_kind, :id

    def initialize(step)
      @step_kind = step.to_s
      @id = SecureRandom.uuid
    end

    def barrier? = true

    def step_kinds = [ step_kind ]

    def to_chain_template
      { "type" => "barrier", "id" => id, "step" => step_kind }
    end
  end
end
