require "rails_helper"

RSpec.describe SyrusMcp do
  describe ".utf8" do
    it "returns clean UTF-8 for a normal string" do
      expect(described_class.utf8("hello")).to eq("hello")
      expect(described_class.utf8("hello").encoding).to eq(Encoding::UTF_8)
    end

    it "force-encodes ASCII_8BIT strings to UTF-8" do
      binary = "Add ● thing".b
      result = described_class.utf8(binary)
      expect(result).to eq("Add ● thing")
      expect(result.encoding).to eq(Encoding::UTF_8)
    end

    it "calls to_s on non-string input" do
      expect(described_class.utf8(nil)).to eq("")
      expect(described_class.utf8(42)).to eq("42")
    end

    it "scrubs invalid byte sequences" do
      bad = "ok\xFF\xFEbytes".b
      result = described_class.utf8(bad)
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to include("ok")
      expect(result).to include("bytes")
    end
  end

  describe ".invalid" do
    it "returns an error MCP::Tool::Response" do
      response = described_class.invalid("something went wrong")
      expect(response).to be_a(MCP::Tool::Response)
      expect(response).to be_error
      expect(response.content.first[:text]).to eq("Error: something went wrong")
    end
  end
end
