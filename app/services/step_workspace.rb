class StepWorkspace
  class PinnedWorkflowWorkspace
    def self.build(step, git:, log:)
      WorkflowWorkspace.new(step.workflow, git: git, log: log)
    end
  end

  class ImmutableSource
    def self.build(step, git:, log:)
      repository = step.workflow.job.repository
      return PinnedWorkflowWorkspace.build(step, git: git, log: log) unless Feature.distributed_workflow_dag_enabled?(repository)

      ImmutableSourceCheckout.new(step, git: git, log: log)
    end
  end

  POLICIES = {
    Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE => PinnedWorkflowWorkspace,
    Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT => ImmutableSource,
    Step::PlacementPolicy::CONTROL_PLANE => PinnedWorkflowWorkspace,
    Step::PlacementPolicy::EXTERNAL_CONTEXT => PinnedWorkflowWorkspace
  }.freeze

  def self.for(step, git: nil, log: nil)
    POLICIES.fetch(step.placement_policy).build(step, git: git, log: log)
  end
end
