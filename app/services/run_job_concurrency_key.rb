class RunJobConcurrencyKey
  def self.for(run_id)
    run = Run.includes(step: { workflow: { job: :repository } }).find_by(id: run_id)
    new(run).key
  end

  def initialize(run)
    @run = run
  end

  def key
    policy_for(run&.step).key
  end

  private

  attr_reader :run

  def policy_for(step)
    policy_class = POLICIES.fetch(step&.placement_policy, PinnedWorkflowWorkspace)
    policy_class.new(run, step)
  end

  class Base
    def initialize(run, step)
      @run = run
      @step = step
    end

    private

    attr_reader :run, :step

    def job_key
      "job:#{run&.job_id}"
    end
  end

  class PinnedWorkflowWorkspace < Base
    def key = job_key
  end

  class ImmutableSourceCheckout < Base
    def key
      return job_key unless distributed_execution_admitted?

      "#{job_key}:immutable_source_step:#{step.id}"
    end

    private

    def distributed_execution_admitted?
      step.present? &&
        step.distributed_workflow_dag_enabled? &&
        WorkflowStepWorkerSlot.enabled?
    end
  end

  class ControlPlane < PinnedWorkflowWorkspace
  end

  class ExternalContext < PinnedWorkflowWorkspace
  end

  POLICIES = {
    Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE => PinnedWorkflowWorkspace,
    Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT => ImmutableSourceCheckout,
    Step::PlacementPolicy::CONTROL_PLANE => ControlPlane,
    Step::PlacementPolicy::EXTERNAL_CONTEXT => ExternalContext
  }.freeze
end
