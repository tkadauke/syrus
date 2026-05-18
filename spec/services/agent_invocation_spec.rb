require "rails_helper"

RSpec.describe AgentInvocation do
  it "keeps shared invocation constants on the namespace" do
    expect(described_class::DEFAULT_TIMEOUT_SECONDS).to eq(90.minutes.to_i)
    expect(described_class::SILENT_TIMEOUT_SECONDS).to eq(20.minutes.to_i)
    expect(described_class::DEFAULT_MAX_TURNS).to eq(200)
    expect(described_class::ENV_FORWARD).to include("PATH")
    expect(described_class::Result).to be_a(Class)
  end
end
