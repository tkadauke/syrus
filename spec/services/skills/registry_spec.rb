require "rails_helper"

RSpec.describe Skills::Registry do
  describe ".values" do
    it "includes the seed built-in skill" do
      expect(described_class.values).to include("investigate")
    end

    it "includes the onboard-to-syrus built-in skill" do
      expect(described_class.values).to include("onboard-to-syrus")
    end

    it "includes the debug built-in skill" do
      expect(described_class.values).to include("debug")
    end

    it "includes the dependency-audit built-in skill" do
      expect(described_class.values).to include("dependency-audit")
    end

    it "includes the explain-failing-ci built-in skill" do
      expect(described_class.values).to include("explain-failing-ci")
    end

    it "includes the coverage-gap-report built-in skill" do
      expect(described_class.values).to include("coverage-gap-report")
    end

    it "includes the dead-code-sweep built-in skill" do
      expect(described_class.values).to include("dead-code-sweep")
    end

    it "includes the license-audit built-in skill" do
      expect(described_class.values).to include("license-audit")
    end

    it "includes the security-review built-in skill" do
      expect(described_class.values).to include("security-review")
    end
  end

  describe ".fetch" do
    it "raises Skills::NotFoundError for an unknown name" do
      expect {
        described_class.fetch("does-not-exist")
      }.to raise_error(Skills::NotFoundError, /does-not-exist/)
    end
  end

  describe ".class_for" do
    it "constantizes the registered class" do
      expect(described_class.class_for("investigate")).to eq(Skills::Investigate)
    end
  end

  describe ".definition_for" do
    it "returns the class's definition" do
      expect(described_class.definition_for("investigate")).to eq(Skills::Investigate.definition)
    end
  end
end
