require "rails_helper"

RSpec.describe Steps::AgentRebase do
  let(:repository) { Factories.repository(owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) do
    Factories.job(
      repository: repository,
      pr_number: 17,
      branch_name: "syrus/issue-42-1"
    )
  end
  let(:workflow) { Workflows::Rebase.instantiate(job: job, base_branch: "syrus/parent-branch") }
  let(:step) { workflow.steps.find_by!(kind: "agent_rebase") }
  let(:run) do
    step.runs.create!(
      job: job,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
  end
  let(:handler) { described_class.new(run) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: nil) }

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:run_agent)
    allow(handler).to receive(:head_sha).and_return("abc1234567890", "def4567890123")
  end

  it "builds the rebase prompt from the observed PR base branch and records the new HEAD" do
    handler.call

    expect(workspace).to have_received(:setup)
    expect(handler).to have_received(:run_agent).with(prompt: run.reload.prompt)
    expect(run.prompt).to include("acme/widgets#17")
    expect(run.prompt).to include("syrus/issue-42-1")
    expect(run.prompt).to include("syrus/parent-branch")
    expect(run.head_sha).to eq("def4567890123")
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("agent_rebase: rebased abc1234")
  end

  it "does not rebuild an existing prompt" do
    run.update!(prompt: "Use this exact rebase prompt.")

    expect(Prompts::Rebase).not_to receive(:new)

    handler.call

    expect(run.reload.prompt).to eq("Use this exact rebase prompt.")
    expect(handler).to have_received(:run_agent).with(prompt: "Use this exact rebase prompt.")
  end

  it "fails when the agent does not advance HEAD" do
    allow(handler).to receive(:head_sha).and_return("abc1234567890", "abc1234567890")

    expect { handler.call }.to raise_error(
      Steps::Base::StepFailed,
      "agent_rebase: agent didn't move HEAD (rebase aborted or no-op)"
    )

    expect(run.reload.head_sha).to be_nil
  end
end
