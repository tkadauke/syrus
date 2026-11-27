require "rails_helper"
RSpec.describe Syrus::PluginHostSurface do
  it "has no internal-reference exceptions by default" do
    expect(described_class::INTENTIONAL_INTERNAL_REFERENCES).to eq({})
    expect(described_class.new.allowed_internal?("ChatSession")).to be(false)
  end

  it "recognizes exact documented internal-reference exceptions" do
    stub_const("Syrus::PluginHostSurface::INTENTIONAL_INTERNAL_REFERENCES", { "InternalService" => "Not stable enough to expose" }.freeze)

    surface = described_class.new
    expect(surface.allowed_internal?("InternalService")).to be(true)
    expect(surface.allowed_internal?("InternalService::Nested")).to be(false)
  end
end
