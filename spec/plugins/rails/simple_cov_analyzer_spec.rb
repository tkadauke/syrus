require "rails_helper"
require "tempfile"

RSpec.describe SyrusRails::SimpleCovAnalyzer do
  let(:fixtures_path) { Rails.root.join("spec/fixtures/simplecov") }

  def fixture(name)
    fixtures_path.join(name)
  end

  describe ".can_parse?" do
    it "returns true when format_hint is 'simplecov'" do
      path = fixture("resultset.json")
      expect(described_class.can_parse?(output_path: path, format_hint: "simplecov")).to be true
    end

    it "returns true when file is named .resultset.json and contains SimpleCov structure" do
      Tempfile.create([".resultset", ".json"]) do |f|
        f.write(File.read(fixture("resultset.json")))
        f.flush
        # Tempfile uses a random prefix; force the basename check via can_parse? directly
        allow(File).to receive(:basename).with(f.path).and_return(".resultset.json")
        expect(described_class.can_parse?(output_path: f.path)).to be true
      end
    end

    it "returns true for the canonical fixture path (basename is .resultset.json)" do
      # The fixture is stored as resultset.json so we verify via format_hint instead
      expect(described_class.can_parse?(output_path: fixture("resultset.json"), format_hint: "simplecov")).to be true
    end

    it "returns false for non-existent files" do
      expect(described_class.can_parse?(output_path: "/no/such/.resultset.json")).to be false
    end

    it "returns false for files that are not valid JSON" do
      Tempfile.create([".resultset", ".json"]) do |f|
        f.write("not json content")
        f.flush
        allow(File).to receive(:basename).with(f.path).and_return(".resultset.json")
        expect(described_class.can_parse?(output_path: f.path)).to be false
      end
    end
  end

  describe ".call" do
    context "with a basic resultset (two files, line coverage only)" do
      let(:result) { described_class.call(output_path: fixture("resultset.json")) }

      it "returns a hash with summary and files keys" do
        expect(result).to include("summary", "files")
      end

      it "computes overall lines_pct correctly" do
        # user.rb:  executable=[1,2,3,5,6] → 5 total, hits at 1,3,5 → 3 covered → 60.0%
        # post.rb:  executable=[0,1,2,4]   → 4 total, hits at 0,1,2   → 3 covered → 75.0%
        # overall:  9 total, 6 covered → 66.67%
        expect(result.dig("summary", "lines_pct")).to eq(66.67)
      end

      it "sets branches_pct to nil when no branch data is present" do
        expect(result.dig("summary", "branches_pct")).to be_nil
      end

      it "sets functions_pct to nil (SimpleCov does not track functions)" do
        expect(result.dig("summary", "functions_pct")).to be_nil
      end

      it "includes per-file coverage for each file in the resultset" do
        expect(result["files"].keys).to contain_exactly(
          "app/models/user.rb",
          "app/models/post.rb"
        )
      end

      it "computes per-file lines_pct for user.rb" do
        # 5 executable, 3 covered → 60.0%
        expect(result.dig("files", "app/models/user.rb", "lines_pct")).to eq(60.0)
      end

      it "computes per-file lines_pct for post.rb" do
        # 4 executable, 3 covered → 75.0%
        expect(result.dig("files", "app/models/post.rb", "lines_pct")).to eq(75.0)
      end
    end

    context "with branch coverage data" do
      let(:result) { described_class.call(output_path: fixture("resultset_with_branches.json")) }

      # order_calculator.rb: lines [null,1,1,0,null,1] → 4 executable, 3 hit → 75.0%
      # branches: 4 keys, 3 non-zero (branch_if_line_3_then:2, line_5_then:1, line_5_else:1) → 75.0%

      it "computes lines_pct from line hits" do
        expect(result.dig("summary", "lines_pct")).to eq(75.0)
      end

      it "computes branches_pct from branch hit counts" do
        expect(result.dig("summary", "branches_pct")).to eq(75.0)
      end

      it "includes branch_pct in per-file entry" do
        file_entry = result.dig("files", "app/services/order_calculator.rb")
        expect(file_entry["branches_pct"]).to eq(75.0)
      end
    end

    context "with merged result sets from multiple test suites" do
      let(:result) { described_class.call(output_path: fixture("merged_resultset.json")) }

      # RSpec:    user.rb lines [null,1,0,3,null]
      # Cucumber: user.rb lines [null,0,1,0,null]
      # Merged:   user.rb lines [null,1,1,3,null] → 3 executable, 3 hit → 100%

      it "merges line hits across result sets (summing per-line hit counts)" do
        expect(result.dig("summary", "lines_pct")).to eq(100.0)
      end

      it "still produces a single entry per file after merging" do
        expect(result["files"].keys).to eq(["app/models/user.rb"])
      end
    end
  end

  describe "SyrusRails.detect?" do
    it "returns true when a directory has Gemfile, config/application.rb, and bin/rails" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Gemfile"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.touch(File.join(dir, "bin", "rails"))

        expect(SyrusRails.detect?(dir)).to be true
      end
    end

    it "returns false when bin/rails is missing" do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, "Gemfile"))
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))

        expect(SyrusRails.detect?(dir)).to be false
      end
    end

    it "returns false when Gemfile is missing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "config"))
        FileUtils.touch(File.join(dir, "config", "application.rb"))
        FileUtils.mkdir_p(File.join(dir, "bin"))
        FileUtils.touch(File.join(dir, "bin", "rails"))

        expect(SyrusRails.detect?(dir)).to be false
      end
    end
  end
end
