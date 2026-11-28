require "rails_helper"

# A Step parked on an operator question is neither active nor terminal. When
# it is the Workflow's last non-terminal Step, the reconciler must not report
# the Workflow as running without descendants: the work is waiting on a
# person, not orphaned.
RSpec.describe WorkEngine::Reconciler do
  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }

  def reconcile
    Workflow.find_each { |candidate| FileUtils.mkdir_p(WorkflowWorkspace.path_for(candidate)) }
    described_class.call(source: "spec", workflow_id: workflow.id)
  end

  it "does not flag a running workflow whose last step awaits an operator answer" do
    workflow.steps.delete_all
    workflow.update!(state: "running", started_at: (described_class::ORPHAN_RUN_GRACE_PERIOD * 2).ago)
    step = workflow.steps.create!(kind: "implement", position: 0, state: "awaiting_answer",
      started_at: (described_class::ORPHAN_RUN_GRACE_PERIOD * 2).ago)
    run = step.runs.create!(job: job, user: job.user, state: "awaiting_answer", agent_provider: "claude", trigger_kind: "initial",
      started_at: (described_class::ORPHAN_RUN_GRACE_PERIOD * 2).ago)
    AgentQuestion.create!(
      run: run, questions: [ { "question" => "Path?", "options" => nil, "multiple" => false } ],
      asked_at: Time.current
    )

    result = reconcile

    expect(result.issues.map(&:kind)).not_to include("running_workflow_without_active_descendants")
  end
end
