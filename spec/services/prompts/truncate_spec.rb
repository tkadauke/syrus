require "rails_helper"

RSpec.describe Prompts::Truncate do
  describe ".text" do
    it "truncates at a valid UTF-8 byte boundary and identifies omitted bytes" do
      text = "é" * 10

      result = described_class.text(text, max_bytes: 5, label: "example")

      expect(result).to start_with("éé")
      expect(result).to include("[example truncated, 15 more bytes]")
      expect(result).to be_valid_encoding
    end
  end

  describe ".collection" do
    it "keeps priority entries and the newest background entries in chronological order" do
      items = %w[oldest old new newest]

      result = described_class.collection(
        items,
        max_items: 1,
        max_bytes: 1_000,
        priority: ->(item) { item == "new" }
      ) { |item| item }

      expect(result).to start_with("new\n\nnewest")
      expect(result).to include("2 comments omitted due to limits")
      expect(result).not_to include("oldest")
    end

    it "enforces the aggregate byte budget with an explicit marker" do
      result = described_class.collection(%w[a b], max_items: 2, max_bytes: 5) { "é" * 10 }

      expect(result).to include("[comment thread entry truncated")
      expect(result).to be_valid_encoding
    end
  end
end
