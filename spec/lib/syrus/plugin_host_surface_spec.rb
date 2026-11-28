require "rails_helper"
RSpec.describe Syrus::PluginHostSurface do
  it "has no internal-reference exceptions by default" do
    expect(described_class::INTENTIONAL_INTERNAL_REFERENCES).to eq({})
    expect(described_class.new.allowed_internal?("ChatSession")).to be(false)
  end
end
