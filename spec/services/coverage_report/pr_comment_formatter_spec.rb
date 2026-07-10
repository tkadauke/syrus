require "rails_helper"

RSpec.describe CoverageReport::PrCommentFormatter do
  let(:threshold) { nil }
  let(:plan) do
    instance_double(SyrusYml::CoverageConfig, threshold: threshold)
  end

  def formatter(artifact_overrides = {})
    artifact = base_artifact.merge(artifact_overrides)
    described_class.new(artifact, plan: plan)
  end

  let(:base_artifact) do
    {
      "summary"          => { "lines_pct" => 82.3, "branches_pct" => 68.1 },
      "pr_delta"         => { "pct" => 90.4, "covered" => 45, "total" => 50, "uncovered_files" => [] },
      "diff_annotations" => {},
      "files"            => {}
    }
  end

  describe "#format" do
    it "starts with the syrus-coverage HTML marker" do
      result = formatter.format
      expect(result).to start_with(CoverageReport::PrCommentFormatter::MARKER)
    end

    it "includes the Test Coverage Report heading" do
      expect(formatter.format).to include("## Test Coverage Report")
    end

    it "renders Lines row from summary" do
      expect(formatter.format).to include("| Lines | 82.3%")
    end

    it "renders Branches row from summary" do
      expect(formatter.format).to include("| Branches | 68.1%")
    end

    it "renders PR delta row" do
      expect(formatter.format).to include("| PR delta | 90.4%")
    end

    it "shows — for threshold when no threshold is configured" do
      expect(formatter.format).to include("| Lines | 82.3% | — | — |")
    end

    context "with a threshold configured" do
      let(:threshold) { instance_double(SyrusYml::CoverageThreshold, lines: 80.0, pr_lines: 90.0) }

      it "shows ✅ when lines_pct meets threshold" do
        result = formatter.format
        expect(result).to include("| Lines | 82.3% | 80.0% | ✅ |")
      end

      it "shows ❌ when lines_pct is below threshold" do
        artifact = base_artifact.merge("summary" => { "lines_pct" => 70.0, "branches_pct" => 50.0 })
        result = described_class.new(artifact, plan: plan).format
        expect(result).to include("| Lines | 70.0% | 80.0% | ❌ |")
      end

      it "shows ✅ when pr_delta_pct meets threshold" do
        expect(formatter.format).to include("| PR delta | 90.4% | 90.0% | ✅ |")
      end

      it "shows ❌ when pr_delta_pct is below threshold" do
        artifact = base_artifact.merge("pr_delta" => { "pct" => 85.0, "covered" => 34, "total" => 40 })
        result = described_class.new(artifact, plan: plan).format
        expect(result).to include("| PR delta | 85.0% | 90.0% | ❌ |")
      end
    end

    context "when coverage_unavailable is true" do
      it "returns nil" do
        result = described_class.new({ "coverage_unavailable" => true }, plan: plan).format
        expect(result).to be_nil
      end
    end

    context "when there are diff annotations" do
      let(:annotations) do
        {
          "app/models/user.rb"      => { "1" => "covered", "2" => "covered", "3" => "covered" },
          "app/services/payment.rb" => { "10" => "covered", "11" => "uncovered", "12" => "uncovered",
                                         "13" => "uncovered", "14" => "not_executable" }
        }
      end
      let(:files) do
        {
          "app/models/user.rb"      => { "lines_pct" => 95.2 },
          "app/services/payment.rb" => { "lines_pct" => 34.1 }
        }
      end

      subject(:result) do
        artifact = base_artifact.merge("diff_annotations" => annotations, "files" => files)
        described_class.new(artifact, plan: plan).format
      end

      it "includes a collapsible per-file details section" do
        expect(result).to include("<details>")
        expect(result).to include("</details>")
        expect(result).to include("Per-file coverage (2 files changed)")
      end

      it "shows full-file line coverage for each changed file" do
        expect(result).to include("| app/models/user.rb | 95.2%")
        expect(result).to include("| app/services/payment.rb | 34.1%")
      end

      it "computes covered/total from diff annotations (excluding not_executable)" do
        expect(result).to include("3/3 covered")
        expect(result).to include("1/4 covered")
      end

      it "adds ⚠️ for files with low changed-line coverage" do
        expect(result).to include("1/4 covered ⚠️")
        expect(result).not_to include("3/3 covered ⚠️")
      end
    end

    context "when diff_annotations is empty" do
      it "omits the per-file details section" do
        result = formatter.format
        expect(result).not_to include("<details>")
      end
    end

    context "when diff annotations contain only not_executable lines" do
      let(:annotations) { { "app/models/concern.rb" => { "1" => "not_executable", "2" => "not_executable" } } }

      it "omits that file from the per-file table" do
        artifact = base_artifact.merge("diff_annotations" => annotations)
        result = described_class.new(artifact, plan: plan).format
        expect(result).not_to include("<details>")
      end
    end

    it "omits Branches row when branches_pct is absent" do
      artifact = base_artifact.merge("summary" => { "lines_pct" => 80.0 })
      result = described_class.new(artifact, plan: plan).format
      expect(result).not_to include("Branches")
    end

    it "omits PR delta row when pr_delta pct is absent" do
      artifact = base_artifact.merge("pr_delta" => { "pct" => nil, "covered" => 0, "total" => 0 })
      result = described_class.new(artifact, plan: plan).format
      expect(result).not_to include("PR delta")
    end
  end
end
