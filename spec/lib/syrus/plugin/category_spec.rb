require "rails_helper"
require "syrus/plugin/category"

RSpec.describe Syrus::Plugin::Category do
  describe ".values" do
    it "returns the canonical set of category keys" do
      expect(described_class.values).to contain_exactly(
        "language", "agent", "input_source", "mcp_tool_set",
        "platform_delivery", "connectivity", "observability", "tooling"
      )
    end

    it "returns a frozen array" do
      expect(described_class.values).to be_frozen
    end
  end

  describe ".valid?" do
    it "returns true for every canonical key" do
      described_class.values.each do |key|
        expect(described_class.valid?(key)).to be(true)
      end
    end

    it "accepts symbols as well as strings" do
      expect(described_class.valid?(:language)).to be(true)
    end

    it "returns false for an unrecognized key" do
      expect(described_class.valid?("not_a_real_category")).to be(false)
    end
  end

  describe ".fetch" do
    it "returns the entry for a known key" do
      entry = described_class.fetch("language")
      expect(entry.key).to eq("language")
      expect(entry.label).to be_present
    end

    it "raises ArgumentError for an unknown key" do
      expect { described_class.fetch("not_a_real_category") }
        .to raise_error(ArgumentError, /unknown plugin category/)
    end
  end

  describe ".label_for" do
    it "returns the human-readable label for a known key" do
      expect(described_class.label_for("mcp_tool_set")).to eq("MCP tool set")
    end

    it "returns nil for an unknown key" do
      expect(described_class.label_for("not_a_real_category")).to be_nil
    end
  end
end
