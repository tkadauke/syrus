require "rails_helper"

RSpec.describe Steps::AutoRebase do
  let(:job) { Factories.job }
  let(:workflow) { Workflows::Rebase.instantiate(job: job) }
  let(:auto_rebase_step) { workflow.steps.find_by!(kind: "auto_rebase") }
  let(:agent_rebase_step) { workflow.steps.find_by!(kind: "agent_rebase") }
  let(:force_push_step) { workflow.steps.find_by!(kind: "force_push") }
  let(:run) { Run.create!(job: job, step: auto_rebase_step, trigger_kind: "rebase") }
  let(:service) { instance_double(::AutoRebase) }

  before do
    allow(::AutoRebase).to receive(:new).and_return(service)
  end

  it "skips only the agent rebase step after a clean deterministic rebase" do
    allow(service).to receive(:call).and_return(::AutoRebase::Result.new(
      true,
      "rebased",
      "advanced abc1234 -> def5678",
      changed: true,
      pre_sha: "abc1234",
      post_sha: "def5678",
      base_sha: "base123"
    ))

    described_class.new(run).call

    expect(::AutoRebase).to have_received(:new).with(job, base_branch: job.effective_base_branch)
    expect(agent_rebase_step.reload.state).to eq("skipped")
    expect(agent_rebase_step.details).to include(
      "skipped" => true,
      "skip_reason" => "auto_rebase already succeeded; agent rebase not needed"
    )
    expect(force_push_step.reload.state).to eq("queued")
    expect(workflow.reload.artifact("auto_rebase_result")).to include(
      "changed" => true,
      "post_sha" => "def5678",
      "base_sha" => "base123"
    )
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("auto_rebase already succeeded")
  end

  describe "when the branch's work is already on the base" do
    let(:already_landed) do
      ::AutoRebase::Result.new(
        true, ::AutoRebase::ALREADY_LANDED_REASON,
        "no commits left ahead of main — this branch's work is already on the base",
        changed: false, pre_sha: "abc1234", post_sha: "base123", base_sha: "base123"
      )
    end

    before do
      allow(service).to receive(:call).and_return(already_landed)
      job.update!(state: "approved", pr_number: 3235, branch_name: "syrus/direct-#{job.id}")
    end

    # The Job landed -- almost always through a merge train whose member
    # reconciliation could not verify it. Left open, the merge-state poller
    # dispatches rebase after rebase against work that is already in.
    it "closes the Job as landed rather than leaving it to be rebased forever" do
      client = instance_double(GithubClient, add_issue_comment: nil, close_pull_request: nil)
      allow(GithubClient).to receive(:for).and_return(client)

      described_class.new(run).call

      expect(job.reload).to be_closed
      expect(job.closure_reason).to eq("pr_merged")
      expect(client).to have_received(:close_pull_request).with(job.repository.slug, 3235)
    end

    it "skips the agent rebase, since there is nothing left to rebase" do
      allow(GithubClient).to receive(:for)
        .and_return(instance_double(GithubClient, add_issue_comment: nil, close_pull_request: nil))

      described_class.new(run).call

      expect(agent_rebase_step.reload.state).to eq("skipped")
    end

    # Finalizing is bookkeeping. A GitHub call that fails must not fail a
    # rebase that correctly declined to do anything.
    it "does not fail the step when the pull request cannot be closed" do
      client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).and_return(client)
      allow(client).to receive(:add_issue_comment).and_raise(Octokit::Error.new)

      expect { described_class.new(run).call }.not_to raise_error
      expect(job.reload).to be_closed
    end
  end

  it "leaves the agent rebase step queued and records the reason when deterministic rebase conflicts" do
    allow(service).to receive(:call).and_return(::AutoRebase::Result.new(false, "conflict", nil))

    described_class.new(run).call

    expect(agent_rebase_step.reload.state).to eq("queued")
    expect(force_push_step.reload.state).to eq("queued")
    expect(workflow.reload.artifact("auto_rebase_reason")).to eq("conflict")
  end

  it "does not rewrite a terminal agent rebase step on a later clean result" do
    agent_rebase_step.start!
    agent_rebase_step.fail!
    agent_rebase_step.save!

    allow(service).to receive(:call).and_return(::AutoRebase::Result.new(true, "rebased", "no-op"))

    described_class.new(run).call

    expect(agent_rebase_step.reload.state).to eq("failed")
  end

  it "passes the captured live PR base branch to AutoRebase" do
    workflow.set_artifact!("rebase_base_branch", "syrus/parent-branch")
    allow(service).to receive(:call).and_return(::AutoRebase::Result.new(false, "conflict", nil))

    described_class.new(run).call

    expect(::AutoRebase).to have_received(:new).with(job, base_branch: "syrus/parent-branch")
  end
end
