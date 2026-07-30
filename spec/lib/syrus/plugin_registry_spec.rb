require "rails_helper"

RSpec.describe Syrus::PluginRegistry do
  after { described_class.reset! }

  describe "EXTENSION_POINTS" do
    it "includes :test_result_parser" do
      expect(described_class::EXTENSION_POINTS).to include(:test_result_parser)
    end

    it "is a frozen array of symbols" do
      expect(described_class::EXTENSION_POINTS).to be_frozen
      expect(described_class::EXTENSION_POINTS).to all(be_a(Symbol))
    end
  end

  describe ".register" do
    it "accepts a provider for a known extension point" do
      provider = double("parser")
      expect { described_class.register(:test_result_parser, provider) }.not_to raise_error
    end

    it "raises ArgumentError for an unknown extension point" do
      expect { described_class.register(:unknown_point, double) }
        .to raise_error(ArgumentError, /Unknown extension point/)
    end

    it "accepts string or symbol for the extension point" do
      provider = double("parser")
      expect { described_class.register("test_result_parser", provider) }.not_to raise_error
    end
  end

  describe ".providers_for" do
    it "returns an empty array when no providers are registered" do
      expect(described_class.providers_for(:test_result_parser)).to eq([])
    end

    it "returns registered providers in registration order" do
      p1 = double("parser_1")
      p2 = double("parser_2")
      described_class.register(:test_result_parser, p1)
      described_class.register(:test_result_parser, p2)

      expect(described_class.providers_for(:test_result_parser)).to eq([ p1, p2 ])
    end

    it "returns a copy so callers cannot mutate the registry" do
      provider = double("parser")
      described_class.register(:test_result_parser, provider)

      list = described_class.providers_for(:test_result_parser)
      list << double("intruder")

      expect(described_class.providers_for(:test_result_parser)).to eq([ provider ])
    end

    it "raises ArgumentError for an unknown extension point" do
      expect { described_class.providers_for(:nope) }
        .to raise_error(ArgumentError, /Unknown extension point/)
    end
  end

  describe ".reset!" do
    it "clears all registered providers" do
      described_class.register(:test_result_parser, double("parser"))
      described_class.reset!
      expect(described_class.providers_for(:test_result_parser)).to eq([])
    end
  end
end
