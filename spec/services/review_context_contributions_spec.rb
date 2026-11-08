require "rails_helper"

RSpec.describe ReviewContextContributions do
  describe ".target_for" do
    let(:provider) do
      Class.new do
        include Syrus::Plugin::ReviewContextContributor
        def self.target_type = "fake"
        def self.legacy_target(reviewer) = reviewer == :owned ? { type: "fake", reference: "1" } : nil
      end
    end

    before { allow(Syrus::PluginRegistry).to receive(:providers_for).with(:review_context_contributor).and_return([ provider ]) }

    it "prefers the target stored on the step" do
      stored = { "type" => "fake", "reference" => "9" }
      expect(described_class.target_for(step_target: stored, reviewer: :owned)).to eq(stored)
    end

    it "maps a historical reviewer to an opaque stringified target" do
      expect(described_class.target_for(step_target: nil, reviewer: :owned)).to eq("type" => "fake", "reference" => "1")
    end

    it "returns nil when no provider claims the reviewer (plugin absent) or there is no reviewer" do
      expect(described_class.target_for(step_target: nil, reviewer: :other)).to be_nil
      expect(described_class.target_for(step_target: nil, reviewer: nil)).to be_nil
    end
  end
end
