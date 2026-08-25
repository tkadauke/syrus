require "rails_helper"

RSpec.describe CommandRedactor do
  describe ".redact" do
    it "redacts an x-access-token URL credential while preserving the surrounding URL" do
      text = "remote: https://x-access-token:ghs_abc123DEF456@github.com/owner/repo.git"

      redacted = described_class.redact(text)

      expect(redacted).to eq("remote: https://x-access-token:[REDACTED]@github.com/owner/repo.git")
      expect(redacted).not_to include("ghs_abc123DEF456")
    end

    it "redacts a generic username:password github.com URL credential" do
      text = "fetch https://someuser:s3cr3t-pass@github.com/owner/repo.git"

      redacted = described_class.redact(text)

      expect(redacted).to eq("fetch https://someuser:[REDACTED]@github.com/owner/repo.git")
      expect(redacted).not_to include("s3cr3t-pass")
    end

    it "redacts bare GitHub personal access tokens of every recognized prefix" do
      %w[ghp github_pat gho ghu ghs ghr].each do |prefix|
        text = "token=#{prefix}_1234567890abcdefABCDEF"

        redacted = described_class.redact(text)

        expect(redacted).to eq("token=[REDACTED]")
      end
    end

    it "redacts multiple occurrences in the same string" do
      text = "ghp_aaaaaaaaaaaaaaaaaaaa and ghp_bbbbbbbbbbbbbbbbbbbb"

      redacted = described_class.redact(text)

      expect(redacted).to eq("[REDACTED] and [REDACTED]")
    end

    it "leaves text with no credentials untouched" do
      text = "bundle install --jobs 4"

      expect(described_class.redact(text)).to eq(text)
    end

    it "coerces a non-string argument via #to_s" do
      expect(described_class.redact(nil)).to eq("")
    end

    it "scrubs invalid byte sequences instead of raising" do
      invalid = (+"prefix \xFF\xFE suffix").force_encoding(Encoding::ASCII_8BIT)

      expect { described_class.redact(invalid) }.not_to raise_error
      expect(described_class.redact(invalid)).to include("prefix").and include("suffix")
    end
  end

  describe ".redact_value" do
    it "redacts a plain string" do
      expect(described_class.redact_value("ghp_1234567890abcdefABCD")).to eq("[REDACTED]")
    end

    it "recursively redacts values inside an array" do
      value = ["safe", "ghp_1234567890abcdefABCD", 42]

      expect(described_class.redact_value(value)).to eq(["safe", "[REDACTED]", 42])
    end

    it "recursively redacts values inside a hash, preserving keys" do
      value = { command: "curl https://x-access-token:ghs_secrettoken123@github.com/x", count: 3 }

      result = described_class.redact_value(value)

      expect(result[:command]).to eq("curl https://x-access-token:[REDACTED]@github.com/x")
      expect(result[:count]).to eq(3)
    end

    it "recursively redacts nested arrays and hashes together" do
      value = { items: [{ token: "ghp_1234567890abcdefABCD" }, "clean"] }

      result = described_class.redact_value(value)

      expect(result[:items][0][:token]).to eq("[REDACTED]")
      expect(result[:items][1]).to eq("clean")
    end

    it "passes through non-string, non-collection values unchanged" do
      expect(described_class.redact_value(42)).to eq(42)
      expect(described_class.redact_value(nil)).to be_nil
      expect(described_class.redact_value(true)).to eq(true)
    end
  end

  describe ".utf8" do
    it "returns a valid UTF-8 string unchanged in content" do
      expect(described_class.utf8("hello")).to eq("hello")
    end

    it "converts ASCII-8BIT input to valid UTF-8, scrubbing invalid bytes" do
      binary = (+"a\xFFb").force_encoding(Encoding::ASCII_8BIT)

      result = described_class.utf8(binary)

      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to be_valid_encoding
      expect(result).to eq("ab")
    end

    it "replaces invalid/undefined bytes in a non-binary encoded string" do
      result = described_class.utf8("hello".dup.force_encoding("ASCII-8BIT"))

      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result).to be_valid_encoding
    end
  end
end
