require "rails_helper"
RSpec.describe Syrus::PluginHostSurface do
  it "has no internal-reference exceptions by default" do
    expect(described_class::INTENTIONAL_INTERNAL_REFERENCES).to eq({})
    expect(described_class.new.allowed_internal?("ChatSession")).to be(false)
  end

  it "uses the same public API aliases and plugin interfaces as the external scanner" do
    surface = described_class.new

    expect(surface.public?("Syrus::Host::Record")).to be(true)
    expect(surface.public?("ApplicationRecord")).to be(true)
    expect(surface.public?("Syrus::PluginApi")).to be(true)
    expect(surface.public?("InternalService")).to be(false)
  end
end
