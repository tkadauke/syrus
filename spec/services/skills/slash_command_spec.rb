require "rails_helper"

RSpec.describe Skills::SlashCommand do
  describe ".parse" do
    it "returns nil for blank text" do
      expect(described_class.parse("")).to be_nil
      expect(described_class.parse(nil)).to be_nil
    end

    it "returns nil for text that isn't a slash command" do
      expect(described_class.parse("hello there")).to be_nil
    end

    it "parses a bare command with no args" do
      match = described_class.parse("/investigate")

      expect(match.name).to eq("investigate")
      expect(match.raw_args).to eq("")
    end

    it "parses a command with trailing args" do
      match = described_class.parse("/investigate question=why is CI red?")

      expect(match.name).to eq("investigate")
      expect(match.raw_args).to eq("question=why is CI red?")
    end

    it "tolerates surrounding whitespace" do
      match = described_class.parse("  /audit  scope=full  ")

      expect(match.name).to eq("audit")
      expect(match.raw_args).to eq("scope=full")
    end

    it "returns nil when the text merely contains a slash mid-sentence" do
      expect(described_class.parse("check the docs at /investigate for details")).to be_nil
    end
  end

  describe ".parse_args" do
    it "parses bare key=value pairs" do
      expect(described_class.parse_args("scope=full verbose=true")).to eq(
        "scope" => "full", "verbose" => "true"
      )
    end

    it "parses double-quoted values containing spaces" do
      expect(described_class.parse_args('question="why is CI red?" scope=full')).to eq(
        "question" => "why is CI red?", "scope" => "full"
      )
    end

    it "parses single-quoted values containing spaces" do
      expect(described_class.parse_args("question='why is CI red?'")).to eq(
        "question" => "why is CI red?"
      )
    end

    it "returns an empty hash for blank args" do
      expect(described_class.parse_args("")).to eq({})
      expect(described_class.parse_args(nil)).to eq({})
    end
  end
end
