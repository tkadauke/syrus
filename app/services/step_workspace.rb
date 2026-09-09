class StepWorkspace
  def self.for(step, git: nil, log: nil)
    if step.placement_policy == Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT &&
        Feature.distributed_workflow_dag_enabled?(step.workflow.job.repository)
      ImmutableSourceCheckout.new(step, git: git, log: log)
    else
      WorkflowWorkspace.new(step.workflow, git: git, log: log)
    end
  end
end
