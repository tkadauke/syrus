require "rails_helper"

RSpec.describe PrCostFooter do
  let(:repository) { Factories.repository }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }

  def create_run(cost:)
    workflow = job.workflows.first
    step = workflow.steps.first
    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      cost_usd: cost
    )
  end

  it "formats the managed PR footer with run count and total cost" do
    job.initial_run.update!(cost_usd: 0.123)
    create_run(cost: 0.456)

    body = described_class.apply("Body", job)

    expect(body).to include("This PR was implemented by Syrus across 2 Runs at a total cost of $0.58.")
    expect(body).to include(described_class::START_MARKER)
    expect(body).to include(described_class::END_MARKER)
  end

  it "replaces an existing managed footer instead of appending another one" do
    job.initial_run.update!(cost_usd: 0.10)
    first = described_class.apply("Body", job)
    create_run(cost: 0.20)

    body = described_class.apply(first, job)

    expect(body.scan("This PR was implemented by Syrus").size).to eq(1)
    expect(body).to include("across 2 Runs at a total cost of $0.30")
  end

  it "strips the managed footer when the repository opts out" do
    job.initial_run.update!(cost_usd: 0.10)
    existing = described_class.apply("Body", job)
    repository.update!(pr_cost_footer_enabled: false)

    body = described_class.apply(existing, job)

    expect(body).to eq("Body")
    expect(body).not_to include("total cost")
  end
end
