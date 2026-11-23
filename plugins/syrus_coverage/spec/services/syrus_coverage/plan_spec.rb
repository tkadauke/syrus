require "rails_helper"

RSpec.describe SyrusCoverage::Plan do
  # A plan the way the repository configuration parser builds it.
  def from_config(hash)
    hash = hash.dup
    artifact = hash.delete("artifact")
    hash["sources"] ||= [ { "artifact" => artifact, "format" => hash.delete("format") || "lcov" } ]
    SyrusCoverage::RepositoryConfiguration.parse(value: hash, version: 1, scope: "root")
  end

  describe "#threshold_miss?" do
    let(:plan_with_threshold) do
      from_config(
        "artifact" => "coverage/lcov.info",
        "threshold" => { "lines" => 80, "pr_lines" => 90 }
      )
    end

    let(:plan_without_threshold) do
      from_config("artifact" => "coverage/lcov.info")
    end

    it "returns false when no threshold is configured" do
      expect(plan_without_threshold.threshold_miss?(lines_pct: 50)).to be(false)
    end

    it "returns false when lines coverage meets the threshold exactly" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 80)).to be(false)
    end

    it "returns false when lines coverage exceeds the threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 95)).to be(false)
    end

    it "returns true when lines coverage falls below the threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 79.9)).to be(true)
    end

    it "returns false when pr_delta_pct is nil and pr_lines threshold is configured" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 85, pr_delta_pct: nil)).to be(false)
    end

    it "returns true when pr_delta_pct falls below the pr_lines threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 85, pr_delta_pct: 85)).to be(true)
    end

    it "returns false when pr_delta_pct meets the pr_lines threshold" do
      expect(plan_with_threshold.threshold_miss?(lines_pct: 85, pr_delta_pct: 90)).to be(false)
    end

    it "returns false when threshold has only branches configured (not checked by this method)" do
      plan = from_config(
        "artifact" => "coverage/lcov.info",
        "threshold" => { "branches" => 80 }
      )
      expect(plan.threshold_miss?(lines_pct: 10)).to be(false)
    end
  end

  describe "#branches_threshold_miss?" do
    let(:plan_with_branches_threshold) do
      from_config("artifact" => "coverage/lcov.info", "threshold" => { "branches" => 70 })
    end

    it "returns false when no threshold is configured" do
      plan = from_config("artifact" => "coverage/lcov.info")
      expect(plan.branches_threshold_miss?(branches_pct: 10)).to be(false)
    end

    it "returns false when threshold.branches is not configured" do
      plan = from_config("artifact" => "coverage/lcov.info", "threshold" => { "lines" => 80 })
      expect(plan.branches_threshold_miss?(branches_pct: 10)).to be(false)
    end

    it "returns false when branches_pct is nil" do
      expect(plan_with_branches_threshold.branches_threshold_miss?(branches_pct: nil)).to be(false)
    end

    it "returns true when branches_pct falls below threshold.branches" do
      expect(plan_with_branches_threshold.branches_threshold_miss?(branches_pct: 69.9)).to be(true)
    end

    it "returns false when branches_pct meets or exceeds threshold.branches" do
      expect(plan_with_branches_threshold.branches_threshold_miss?(branches_pct: 70)).to be(false)
      expect(plan_with_branches_threshold.branches_threshold_miss?(branches_pct: 95)).to be(false)
    end

    it "is independent of lines threshold misses" do
      plan = from_config(
        "artifact" => "coverage/lcov.info",
        "threshold" => { "lines" => 80, "branches" => 70 }
      )
      expect(plan.threshold_miss?(lines_pct: 10)).to be(true)
      expect(plan.branches_threshold_miss?(branches_pct: 95)).to be(false)
    end
  end
end
