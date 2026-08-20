require "rails_helper"

RSpec.describe ChatProviders do
  describe ChatProviders::Base do
    it "does not crash when an anonymous provider class uses the fallback key" do
      provider_class = Class.new(described_class)

      expect(provider_class.provider).to eq("unknown")
    end
  end

  it "resolves configured chat provider adapters" do
    expect(described_class.for("claude")).to eq(ChatProviders::Claude)
    expect(described_class.for("codex")).to eq(ChatProviders::Codex)
  end

  it "lists chat provider keys from enabled plugins" do
    expect(described_class.provider_keys).to eq(%w[claude codex])
  end

  it "raises for unknown chat providers" do
    expect {
      described_class.for("oracle")
    }.to raise_error(ChatProviders::ConfigurationError, /Unknown chat provider/)
  end
end
