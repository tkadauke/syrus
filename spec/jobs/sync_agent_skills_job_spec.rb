require "rails_helper"

RSpec.describe SyncAgentSkillsJob do
  describe "#perform" do
    it "delegates to AgentSkillsSyncer.sync" do
      expect(AgentSkillsSyncer).to receive(:sync).once
      described_class.new.perform
    end
  end
end
