require "rails_helper"

RSpec.describe ChatSessionRehydrator do
  describe ".for" do
    it "returns the Claude rehydrator class for 'claude'" do
      expect(described_class.for("claude")).to eq(ChatSessionRehydrator::Claude)
    end

    it "returns the Codex rehydrator class for 'codex'" do
      expect(described_class.for("codex")).to eq(ChatSessionRehydrator::Codex)
    end

    it "returns nil for an unknown provider" do
      expect(described_class.for("oracle")).to be_nil
    end

    it "accepts symbol-coercible values" do
      expect(described_class.for("claude")).to eq(ChatSessionRehydrator::Claude)
    end
  end
end
