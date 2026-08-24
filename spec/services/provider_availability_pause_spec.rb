require "rails_helper"

RSpec.describe ProviderAvailabilityPause do
  let(:user) { Factories.user(claude_oauth_token: "sk-ant-oat01-abc") }
  let(:job) { Factories.job(user: user, repository: Factories.repository(user: user)) }
  let(:workflow) { job.latest_workflow.tap { |w| w.update!(agent_provider: "claude") } }

  describe "#call for the claude provider" do
    it "refreshes a stale Claude usage probe before computing availability" do
      workflow # force Job/Workflow creation (which itself opportunistically probes) before stubbing
      allow(ClaudeUsageProbe).to receive(:stale?).with(user, now: anything).and_return(true)
      allow(ClaudeUsageProbe).to receive(:refresh_for).with(user: user)

      described_class.call(workflow: workflow)

      expect(ClaudeUsageProbe).to have_received(:refresh_for).with(user: user).once
    end

    it "does not refresh when the last Claude probe evidence is still fresh" do
      allow(ClaudeUsageProbe).to receive(:stale?).with(user, now: anything).and_return(false)
      allow(ClaudeUsageProbe).to receive(:refresh_for)

      described_class.call(workflow: workflow)

      expect(ClaudeUsageProbe).not_to have_received(:refresh_for)
    end

    it "does not probe when the user has no Claude OAuth token configured" do
      user.update!(claude_oauth_token: nil)
      allow(ClaudeUsageProbe).to receive(:refresh_for)

      described_class.call(workflow: workflow)

      expect(ClaudeUsageProbe).not_to have_received(:refresh_for)
    end

    it "never touches CodexUsageProbe while gating a Claude workflow" do
      allow(ClaudeUsageProbe).to receive(:stale?).and_return(false)
      allow(CodexUsageProbe).to receive(:refresh_for)

      described_class.call(workflow: workflow)

      expect(CodexUsageProbe).not_to have_received(:refresh_for)
    end
  end

  describe "#call for the codex provider" do
    let(:user) { Factories.user(codex_auth_mode: "chatgpt_login") }
    let(:workflow) { job.latest_workflow.tap { |w| w.update!(agent_provider: "codex") } }

    it "refreshes a stale Codex usage probe before computing availability" do
      workflow
      allow(CodexUsageProbe).to receive(:stale?).with(user, now: anything).and_return(true)
      allow(CodexUsageProbe).to receive(:refresh_for).with(user: user)

      described_class.call(workflow: workflow)

      expect(CodexUsageProbe).to have_received(:refresh_for).with(user: user).once
    end
  end

  describe "#refresh_stale_usage for a provider with no registered AgentProviders class" do
    it "does not raise, matching the prior silent no-op for unrecognized providers" do
      unknown_workflow = instance_double(Workflow, agent_provider: "mystery", job: job, user: user)
      instance = described_class.new(workflow: unknown_workflow)

      expect { instance.send(:refresh_stale_usage) }.not_to raise_error
    end
  end
end
