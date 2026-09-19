require "rails_helper"

RSpec.describe GitBranchName do
  describe ".normalize" do
    it "strips surrounding whitespace and returns nil for blank names" do
      expect(described_class.normalize(" syrus/incident ")).to eq("syrus/incident")
      expect(described_class.normalize("  ")).to be_nil
      expect(described_class.normalize(nil)).to be_nil
    end
  end

  describe ".valid?" do
    it "accepts ordinary branch names" do
      expect(described_class.valid?("syrus/incident-fix")).to be(true)
      expect(described_class.valid?("dependabot/bundler/rack-3.1.1")).to be(true)
    end

    it "rejects unsafe or invalid branch names" do
      [
        "",
        "/leading-slash",
        "-leading-dash",
        "trailing-slash/",
        "trailing-dot.",
        "double//slash",
        "parent..ref",
        "refs/heads/main.lock",
        "syrus/.hidden",
        "bad branch",
        "bad~ref",
        "bad^ref",
        "bad:ref",
        "bad?ref",
        "bad*ref",
        "bad[ref",
        "bad\\ref"
      ].each do |branch_name|
        expect(described_class.valid?(branch_name)).to be(false), "expected #{branch_name.inspect} to be invalid"
      end
    end
  end
end
