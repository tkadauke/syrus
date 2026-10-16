require "rails_helper"

RSpec.describe Prompts::Truncate do
  let(:workspace_path) { Pathname(Dir.mktmpdir) }

  after { FileUtils.rm_rf(workspace_path) }

  describe ".text" do
    it "truncates at a valid UTF-8 byte boundary and identifies omitted bytes" do
      text = "é" * 10

      result = described_class.text(text, max_bytes: 5, label: "example")

      expect(result).to start_with("éé")
      expect(result).to include("[example truncated, 16 more bytes]")
      expect(result).to be_valid_encoding
    end

    it "spills the exact multibyte source and includes its relative path" do
      spill = described_class::Spill.new(workspace_path: workspace_path, key: 42)
      text = "café ☕" * 10

      result = described_class.text(text, max_bytes: 8, label: "Issue Body", spill: spill)

      relative_path = ".syrus/prompt-context/42/issue-body.txt"
      expect(result).to include("full text: #{relative_path}")
      expect(workspace_path.join(relative_path).read).to eq(text)
    end

    it "does not create a spill file when text is not truncated" do
      spill = described_class::Spill.new(workspace_path: workspace_path, key: 42)

      expect(described_class.text("short", max_bytes: 10, spill: spill)).to eq("short")
      expect(workspace_path.join(".syrus")).not_to exist
    end

    it "keeps the path out of the marker when no workspace spill is provided" do
      result = described_class.text("long text", max_bytes: 4, label: "example")

      expect(result).to include("[example truncated, 5 more bytes]")
      expect(result).not_to include("full text:")
    end

    it "uses a unique filename for repeated labels" do
      spill = described_class::Spill.new(workspace_path: workspace_path, key: 42)

      first = described_class.text("first value", max_bytes: 1, label: "comment", spill: spill)
      second = described_class.text("second value", max_bytes: 1, label: "comment", spill: spill)

      expect(first).to include("comment.txt")
      expect(second).to include("comment-2.txt")
    end

    it "caps the total content spilled by one prompt" do
      spill = described_class::Spill.new(workspace_path: workspace_path, key: 42, max_bytes: 12)

      first = described_class.text("first value", max_bytes: 1, label: "first", spill: spill)
      second = described_class.text("second value", max_bytes: 1, label: "second", spill: spill)

      expect(first).to include("full text:")
      expect(second).not_to include("full text:")
      expect(workspace_path.join(".syrus/prompt-context/42/second.txt")).not_to exist
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

    it "removes the last background entry before a preceding priority entry under byte pressure" do
      items = %w[priority background]

      result = described_class.collection(
        items,
        max_items: 1,
        max_bytes: 8,
        priority: ->(item) { item == "priority" }
      ) { |item| item }

      expect(result).to start_with("priority")
      expect(result).not_to include("background")
      expect(result).to include("1 comment omitted due to limits")
    end

    it "spills every omitted item, including priority items removed by byte pressure" do
      spill = described_class::Spill.new(workspace_path: workspace_path, key: 7)
      items = %w[priority background]

      result = described_class.collection(
        items,
        max_items: 1,
        max_bytes: 8,
        priority: ->(item) { item == "priority" },
        spill: spill
      ) { |item| item }

      relative_path = ".syrus/prompt-context/7/comments-omitted.md"
      expect(result).to include("full text: #{relative_path}")
      expect(workspace_path.join(relative_path).read).to eq("background")
    end

    it "includes a priority item removed by byte pressure in the omitted file" do
      spill = described_class::Spill.new(workspace_path: workspace_path, key: 8)

      described_class.collection(
        %w[first second],
        max_items: 0,
        max_bytes: 6,
        priority: ->(_item) { true },
        spill: spill
      ) { |item| item }

      expect(workspace_path.join(".syrus/prompt-context/8/comments-omitted.md").read).to eq("first")
    end
  end
end
