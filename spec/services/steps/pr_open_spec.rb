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
end
