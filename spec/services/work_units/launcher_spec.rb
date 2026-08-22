require "rails_helper"

RSpec.describe WorkUnits::Launcher do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "instantiates the workflow template declared by the work definition" do
    workflow = described_class.instantiate(kind: "manual_visual_review", job: job)

    expect(workflow).to be_persisted
    expect(workflow).to have_attributes(job: job, trigger_kind: "manual_visual_review")
    expect(workflow.steps.pluck(:kind)).to eq(%w[prepare visual_review])
  end

  it "passes artifacts and agent provider through to the workflow template" do
    workflow = described_class.instantiate(
      kind: "ci_failure",
      job: job,
      artifacts: { "head_sha" => "abc123" },
      agent_provider: "codex"
    )

    expect(workflow.trigger_kind).to eq("ci_failure")
    expect(workflow.agent_provider).to eq("codex")
    expect(workflow.artifact("head_sha")).to eq("abc123")
  end

  it "passes workflow-specific options through to specialized templates" do
    workflow = described_class.instantiate(
      kind: "rebase",
      job: job,
      base_branch: "syrus/parent"
    )

    expect(workflow.trigger_kind).to eq("rebase")
    expect(workflow.artifact(RebaseTarget::BASE_BRANCH_ARTIFACT)).to eq("syrus/parent")
  end
end
