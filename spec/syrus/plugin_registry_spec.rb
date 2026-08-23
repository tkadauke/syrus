require "rails_helper"

RSpec.describe Syrus::PluginRegistry do
  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".register / .providers_for" do
    let(:provider) { double("provider") }

    it "registers a provider under a valid extension point" do
      described_class.register(:preview_provider, provider)
      expect(described_class.providers_for(:preview_provider)).to eq([provider])
    end

    it "accepts extension point as a string" do
      described_class.register("preview_provider", provider)
      expect(described_class.providers_for("preview_provider")).to eq([provider])
    end

    it "returns an empty array when nothing is registered" do
      expect(described_class.providers_for(:preview_provider)).to eq([])
    end

    it "returns a dup so mutations do not corrupt the registry" do
      described_class.register(:preview_provider, provider)
      described_class.providers_for(:preview_provider) << double("intruder")
      expect(described_class.providers_for(:preview_provider)).to eq([provider])
    end

    it "accumulates multiple providers for the same extension point" do
      a = double("a")
      b = double("b")
      described_class.register(:preview_provider, a)
      described_class.register(:preview_provider, b)
      expect(described_class.providers_for(:preview_provider)).to eq([a, b])
    end

    it "keeps extension points isolated from each other" do
      described_class.register(:preview_provider, provider)
      expect(described_class.providers_for(:coverage_analyzer)).to eq([])
    end

    it "raises ArgumentError for an unknown extension point on register" do
      expect { described_class.register(:nonexistent, provider) }
        .to raise_error(ArgumentError, /Unknown extension point: :nonexistent/)
    end

    it "raises ArgumentError for an unknown extension point on providers_for" do
      expect { described_class.providers_for(:nonexistent) }
        .to raise_error(ArgumentError, /Unknown extension point: :nonexistent/)
    end
  end

  describe ".reset!" do
    it "clears all registered providers" do
      described_class.register(:preview_provider, double("provider"))
      described_class.reset!
      expect(described_class.providers_for(:preview_provider)).to eq([])
    end
  end

  describe "EXTENSION_POINTS" do
    it "includes :preview_provider" do
      expect(described_class::EXTENSION_POINTS).to include(:preview_provider)
    end

    it "includes all expected extension points" do
      expect(described_class::EXTENSION_POINTS).to include(
        :agent_provider, :chat_provider, :mcp_tool_set, :input_source, :prompt_injector,
        :artifact_renderer, :test_result_parser, :coverage_analyzer, :preview_provider,
        :admin_page, :sidebar_page, :chat_mcp_tool_set, :source_control_provider
      )
    end
  end
end
