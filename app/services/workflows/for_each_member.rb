module Workflows
  # Runs a step once per member of the WorkUnit (workflow-engine-v3 primitive E).
  #
  # `WorkUnit` already models members and locks honestly, but the graph does
  # not run over them -- a merge train executes against a representative Job,
  # so its real shape lives inside `Steps::MergeTrainBuild` and needs its own
  # retry policy, failure handler, `EpicLandingRetrier`, and the `:rebuild`
  # repair semantics value. A node that fans out over members is what lets that
  # shape live in a template instead.
  #
  # Members are only known at run time, so this materializes as a single
  # fan-out Step; the per-member Steps are inserted when it runs, exactly the
  # way `Steps::GraderFanout` already inserts one Step per configured grader.
  # That is why `grader` and this share `runtime_inserted` on Step::Kind.
  #
  # `preemption` attaches the policy to the node rather than only to the work
  # definition, so "what happens if this is preempted mid-train" has a declared
  # per-node answer. All three values already exist as WorkUnit behaviors.
  class ForEachMember
    PREEMPTIONS = %w[checkpoint cancel rebuild].freeze

    attr_reader :step_kind, :id, :preemption

    def initialize(step, preemption: "checkpoint")
      @step_kind = step.to_s
      @preemption = preemption.to_s
      raise ArgumentError, "unknown preemption=#{preemption.inspect}" unless PREEMPTIONS.include?(@preemption)

      @id = SecureRandom.uuid
    end

    def for_each_member? = true

    def step_kinds = [ step_kind ]

    def to_chain_template
      {
        "type" => "for_each_member",
        "id" => id,
        "step" => step_kind,
        "preemption" => preemption
      }
    end
  end
end
