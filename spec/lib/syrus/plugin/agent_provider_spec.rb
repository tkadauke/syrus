require "rails_helper"
require "syrus/plugin/agent_provider"

RSpec.describe Syrus::Plugin::AgentProvider do
  let(:concrete) do
    Class.new do
      include Syrus::Plugin::AgentProvider

      def self.provider_key = "fake"
      def self.display_name = "Fake"
      def self.available? = true
    end
  end

  describe "interface defaults" do
    it "defaults available_models to an empty array" do
      expect(concrete.available_models).to eq([])
    end

    it "defaults configured_for_user? to false" do
      expect(concrete.configured_for_user?(nil)).to eq(false)
    end
  end

  describe "ModelInfo" do
    it "exposes id, display_name, context_window, and cost_tier" do
      info = described_class::ModelInfo.new(
        id: "some-model", display_name: "Some Model",
        context_window: :large, cost_tier: :medium
      )

      expect(info.id).to eq("some-model")
      expect(info.display_name).to eq("Some Model")
      expect(info.context_window).to eq(:large)
      expect(info.cost_tier).to eq(:medium)
    end
  end
end
