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
end
