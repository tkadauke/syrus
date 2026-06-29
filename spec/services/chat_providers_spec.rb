require "rails_helper"

RSpec.describe ChatProviders do
  it "resolves configured chat provider adapters" do
    expect(described_class.for("claude")).to eq(ChatProviders::Claude)
    expect(described_class.for("codex")).to eq(ChatProviders::Codex)
  end

  it "raises for unknown chat providers" do
    expect {
      described_class.for("oracle")
    }.to raise_error(ChatProviders::ConfigurationError, /Unknown chat provider/)
  end
end
