require "rails_helper"

RSpec.describe Workflow::CoverageArtifact do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }

  describe ".read" do
    it "returns nil when the coverage artifact has not been written" do
      expect(described_class.read(workflow)).to be_nil
    end

    it "returns the coverage hash after it has been written" do
      payload = { "summary" => { "lines_pct" => 91.5 }, "threshold_miss" => false }
      described_class.write!(workflow, payload)

      expect(described_class.read(workflow)).to eq(payload)
    end
  end

  describe ".write!" do
    it "persists the coverage artifact on the workflow" do
      payload = { "summary" => { "lines_pct" => 85.0 }, "coverage_unavailable" => false }
      described_class.write!(workflow, payload)

      expect(workflow.reload.artifact(described_class::ARTIFACT_KEY)).to eq(payload)
    end

    it "overwrites a previously written coverage artifact" do
      described_class.write!(workflow, { "coverage_unavailable" => true })
      described_class.write!(workflow, { "coverage_unavailable" => false, "summary" => { "lines_pct" => 90.0 } })

      result = described_class.read(workflow.reload)
      expect(result["coverage_unavailable"]).to be false
      expect(result["summary"]["lines_pct"]).to eq(90.0)
    end
  end

  describe "ARTIFACT_KEY" do
    it "is 'coverage'" do
      expect(described_class::ARTIFACT_KEY).to eq("coverage")
    end
  end

  describe "ANNOTATION_VALUES" do
    it "includes covered, uncovered, and not_executable" do
      expect(described_class::ANNOTATION_VALUES).to contain_exactly("covered", "uncovered", "not_executable")
    end
  end
end
