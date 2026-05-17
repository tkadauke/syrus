require "rails_helper"

RSpec.describe Steps::PrOpen do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "retry", agent_provider: workflow_provider) }
  let(:workflow_provider) { "claude" }
  let!(:implement_step) { Step.create!(workflow: workflow, kind: "implement", position: 0) }
  let!(:pr_open_step) { Step.create!(workflow: workflow, kind: "pr_open", position: 1) }

  def composed_body_for(provider:, turns:)
    Run.create!(
      job: job,
      step: implement_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: provider,
      agent_turns: turns
    )
    pr_open_run = Run.create!(
      job: job,
      step: pr_open_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )

    described_class.new(pr_open_run).send(:compose_body, "Body")
  end

  it "includes the authoring agent and turn count for Claude-authored PRs" do
    body = composed_body_for(provider: "claude", turns: 7)

    expect(body).to include("*Authored by Claude (Run took 7 turn(s), trigger=retry). Review carefully.*")
  end

  it "includes the authoring agent but omits turn count for Codex-authored PRs" do
    body = composed_body_for(provider: "codex", turns: 1)

    expect(body).to include("*Authored by Codex (trigger=retry). Review carefully.*")
    expect(body).not_to include("Run took")
  end

  it "passes the Job to PullRequestOpener so dependent PRs use their effective base" do
    pr_open_run = Run.create!(
      job: job,
      step: pr_open_step,
      trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider
    )
    handler = described_class.new(pr_open_run)
    workspace = instance_double(WorkflowWorkspace, setup: true, branch_name: "syrus/issue-42-#{job.id}")
    opener = instance_double(PullRequestOpener)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:push_branch)
    allow(handler).to receive(:pr_title_and_body).and_return([ "T", "B" ])
    expect(PullRequestOpener).to receive(:new).with(repository).and_return(opener)
    expect(opener).to receive(:open).with(
      branch: "syrus/issue-42-#{job.id}",
      title: "T",
      body: "B",
      job: job
    ).and_return(99)

    handler.call

    expect(job.reload.pr_number).to eq(99)
  end

  context "when falling back to the second-shot summarizer" do
    let(:user) { Factories.user(agent_provider: "codex", codex_api_key: "sk-test") }
    let(:workflow_provider) { "codex" }

    it "passes the active provider adapter instead of Claude credentials" do
      Run.create!(
        job: job,
        step: implement_step,
        trigger_kind: workflow.trigger_kind,
        agent_provider: "codex",
        agent_diff: "diff --git a/feature.rb b/feature.rb\n+def x = 1\n"
      )
      pr_open_run = Run.create!(
        job: job,
        step: pr_open_step,
        trigger_kind: workflow.trigger_kind,
        agent_provider: "codex"
      )
      handler = described_class.new(pr_open_run)
      allow(handler).to receive(:pr_summarizer_context)
        .and_return(Struct.new(:title, :body).new("Issue", "Body"))

      expect(PrSummarizer).to receive(:new) do |kwargs|
        expect(kwargs[:agent]).to be_a(AgentProviders::Codex)
        expect(kwargs).not_to have_key(:oauth_token)
        double(call: PrSummarizer::Result.new(title: "Fallback title", body: "Fallback body", error: nil))
      end

      expect(handler.send(:pr_title_and_body_from_summarizer))
        .to eq([ "Fallback title", "Fallback body" ])
    end
  end
end
