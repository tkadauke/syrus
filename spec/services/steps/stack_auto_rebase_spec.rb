require "rails_helper"

RSpec.describe Steps::StackAutoRebase do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) do
    Factories.job(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 7,
      branch_name: "syrus/issue-42-1"
    )
  end
  let!(:child) do
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 43,
      pr_number: 8,
      branch_name: "syrus/issue-43-2",
      parent_job: job
    )
  end
  let(:workflow) { Workflows::StackRebase.instantiate(job: job) }
  let(:auto_step) { workflow.steps.find_by!(kind: "stack_auto_rebase") }
  let(:agent_step) { workflow.steps.find_by!(kind: "stack_agent_rebase") }
  let(:run) { Run.create!(job: job, step: auto_step, trigger_kind: "stack_rebase") }

  it "cancels the agent step when every branch rebases deterministically" do
    root_result = AutoRebase::Result.new(true, "rebased", "advanced root", changed: true, pre_sha: "a", post_sha: "b", base_sha: "m")
    child_result = AutoRebase::Result.new(true, "rebased", "no-op", changed: false, pre_sha: "c", post_sha: "c", base_sha: "b")
    allow(AutoRebase).to receive(:new)
      .with(job, base_branch: "main")
      .and_return(instance_double(AutoRebase, call: root_result))
    allow(AutoRebase).to receive(:new)
      .with(child, base_branch: "syrus/issue-42-1")
      .and_return(instance_double(AutoRebase, call: child_result))

    described_class.new(run).call

    expect(agent_step.reload.state).to eq("cancelled")
    expect(workflow.reload.artifact("stack_rebase_agent_pending")).to eq([])
    expect(workflow.artifact("stack_rebase_results").map { |entry| entry.dig("result", "reason") }).to eq(%w[ rebased rebased ])
  end

  it "stops at the first conflict and leaves the rest for one agent run" do
    conflict = AutoRebase::Result.new(false, "conflict", nil, pre_sha: "a", base_sha: "m")
    allow(AutoRebase).to receive(:new)
      .with(job, base_branch: "main")
      .and_return(instance_double(AutoRebase, call: conflict))
    expect(AutoRebase).not_to receive(:new).with(child, anything)

    described_class.new(run).call

    expect(agent_step.reload.state).to eq("queued")
    expect(workflow.reload.artifact("stack_rebase_agent_pending").map { |entry| entry["job_id"] }).to eq([ job.id, child.id ])
  end
end
