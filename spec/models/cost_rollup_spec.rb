require "rails_helper"

RSpec.describe "cost rollups" do
  let(:repository) { Factories.repository }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }

  def add_run(workflow, cost:)
    step = workflow.steps.first
    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      cost_usd: cost
    )
  end

  it "aggregates cost across Runs in a Workflow" do
    workflow = job.workflows.first
    job.initial_run.update!(cost_usd: 0.11)
    add_run(workflow, cost: 0.22)

    expect(workflow.total_cost_usd).to eq(BigDecimal("0.33"))
  end

  it "aggregates cost across Workflows in a Job" do
    initial = job.workflows.first
    follow_up = Workflows::Retry.instantiate(job: job)
    job.initial_run.update!(cost_usd: 0.11)
    add_run(initial, cost: 0.22)
    add_run(follow_up, cost: 0.33)

    expect(job.total_cost_usd).to eq(BigDecimal("0.66"))
  end
end
