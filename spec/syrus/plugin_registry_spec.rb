require "rails_helper"

RSpec.describe Syrus::PluginRegistry do
  around do |example|
    described_class.reset!
    example.run
    described_class.reset!
  end

  describe ".register" do
    it "stores a registration and returns it via registrations" do
      described_class.register(name: "test-plugin", version: "1.0.0", provides: {})
      expect(described_class.registrations.map(&:name)).to include("test-plugin")
    end

    it "normalizes string extension point keys to symbols" do
      described_class.register(name: "p", version: "1", provides: { "artifact_renderer" => :Dummy })
      expect(described_class.providers_for(:artifact_renderer)).to eq([ :Dummy ])
    end

    it "raises on unknown extension points" do
      expect {
        described_class.register(name: "p", version: "1", provides: { not_a_thing: :X })
      }.to raise_error(ArgumentError, /unknown extension points/)
    end

    it "allows multiple registrations to accumulate" do
      described_class.register(name: "a", version: "1", provides: { artifact_renderer: :A })
      described_class.register(name: "b", version: "1", provides: { artifact_renderer: :B })
      expect(described_class.providers_for(:artifact_renderer)).to eq([ :A, :B ])
    end

    it "accepts array values for an extension point" do
      described_class.register(name: "p", version: "1", provides: { artifact_renderer: [ :X, :Y ] })
      expect(described_class.providers_for(:artifact_renderer)).to eq([ :X, :Y ])
    end

    it "allows omitting extension points — only declared ones appear" do
      described_class.register(name: "p", version: "1", provides: { coverage_analyzer: :Cov })
      expect(described_class.providers_for(:artifact_renderer)).to eq([])
      expect(described_class.providers_for(:coverage_analyzer)).to eq([ :Cov ])
    end
  end

  describe ".providers_for" do
    it "returns an empty array when no plugins are registered" do
      expect(described_class.providers_for(:artifact_renderer)).to eq([])
    end

    it "raises on unknown extension points" do
      expect { described_class.providers_for(:unknown_point) }.to raise_error(ArgumentError, /unknown extension point/)
    end

    it "returns a defensive copy so callers cannot mutate internal state" do
      described_class.register(name: "p", version: "1", provides: { artifact_renderer: :A })
      copy = described_class.providers_for(:artifact_renderer)
      copy << :B
      expect(described_class.providers_for(:artifact_renderer)).to eq([ :A ])
    end
  end

  describe ".reset!" do
    it "clears all registrations" do
      described_class.register(name: "p", version: "1", provides: {})
      described_class.reset!
      expect(described_class.registrations).to be_empty
    end
  end

  describe "EXTENSION_POINTS" do
    it "includes all eight expected extension points" do
      expect(described_class::EXTENSION_POINTS).to contain_exactly(
        :agent_provider, :mcp_tool_set, :input_source, :prompt_injector,
        :artifact_renderer, :test_result_parser, :coverage_analyzer, :preview_provider
      )
    end
  end
end
