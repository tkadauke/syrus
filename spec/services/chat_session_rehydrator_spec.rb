require "rails_helper"

RSpec.describe ChatSessionRehydrator do
  describe ".for" do
    before do
      PluginRecord.find_or_create_by!(name: "muse_agent").update!(enabled: true, default_enabled: false, disableable: true)
    end

    it "returns the Claude rehydrator class for 'claude'" do
      expect(described_class.for("claude")).to eq(ChatSessionRehydrator::Claude)
    end

    it "returns the Codex rehydrator class for 'codex'" do
      expect(described_class.for("codex")).to eq(ChatSessionRehydrator::Codex)
    end

    it "returns the Muse rehydrator class for 'muse'" do
      expect(described_class.for("muse")).to eq(ChatSessionRehydrator::Muse)
    end

    it "returns nil for an unknown provider" do
      expect(described_class.for("oracle")).to be_nil
    end

    it "accepts symbol-coercible values" do
      expect(described_class.for("claude")).to eq(ChatSessionRehydrator::Claude)
    end

    it "uses providers registered at runtime" do
      rehydrator = Class.new

      described_class.register("oracle", rehydrator)

      expect(described_class.for("oracle")).to eq(rehydrator)
    end
  end
end
