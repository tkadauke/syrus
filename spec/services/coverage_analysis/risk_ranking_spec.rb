require "rails_helper"

RSpec.describe CoverageAnalysis::RiskRanking do
  describe ".rank" do
    # Fixture: two files with identical low coverage, but one churns
    # constantly and the other hasn't been touched recently. The
    # frequently-changed file must outrank the stable one, per the
    # issue's "weight by recent change frequency... a stable low-coverage
    # file is lower priority than a frequently-changed one."
    it "ranks a frequently-changed low-coverage file above an equally low-coverage but stable file" do
      files = {
        "app/hot_path.rb"    => { "lines_pct" => 20.0, "branches_pct" => 10.0 },
        "app/stable_file.rb" => { "lines_pct" => 20.0, "branches_pct" => 10.0 }
      }
      change_frequency = { "app/hot_path.rb" => 15, "app/stable_file.rb" => 0 }

      ranked = described_class.rank(files: files, change_frequency: change_frequency)

      expect(ranked.map(&:path)).to eq([ "app/hot_path.rb", "app/stable_file.rb" ])
      expect(ranked.first.risk_score).to be > ranked.second.risk_score
    end

    it "still ranks a stable low-coverage file above a well-covered, frequently-changed file" do
      files = {
        "app/never_tested.rb" => { "lines_pct" => 0.0, "branches_pct" => 0.0 },
        "app/well_tested.rb"  => { "lines_pct" => 98.0, "branches_pct" => 95.0 }
      }
      change_frequency = { "app/never_tested.rb" => 0, "app/well_tested.rb" => 20 }

      ranked = described_class.rank(files: files, change_frequency: change_frequency)

      expect(ranked.map(&:path)).to eq([ "app/never_tested.rb", "app/well_tested.rb" ])
    end

    it "treats a file with no recorded coverage (nil lines_pct) as maximally uncovered" do
      files = {
        "app/no_data.rb"   => { "lines_pct" => nil, "branches_pct" => nil },
        "app/partial.rb"   => { "lines_pct" => 50.0, "branches_pct" => 40.0 }
      }

      ranked = described_class.rank(files: files, change_frequency: {})

      no_data = ranked.find { |f| f.path == "app/no_data.rb" }
      partial = ranked.find { |f| f.path == "app/partial.rb" }
      expect(no_data.risk_score).to eq(100.0)
      expect(no_data.risk_score).to be > partial.risk_score
    end

    it "defaults change_count to 0 for a file absent from change_frequency" do
      files = { "app/untracked.rb" => { "lines_pct" => 50.0, "branches_pct" => 50.0 } }

      ranked = described_class.rank(files: files, change_frequency: {})

      expect(ranked.first.change_count).to eq(0)
      expect(ranked.first.risk_score).to eq(50.0)
    end

    it "breaks ties on risk_score by path ascending, for deterministic output" do
      files = {
        "z_file.rb" => { "lines_pct" => 0.0, "branches_pct" => 0.0 },
        "a_file.rb" => { "lines_pct" => 0.0, "branches_pct" => 0.0 }
      }

      ranked = described_class.rank(files: files, change_frequency: {})

      expect(ranked.map(&:path)).to eq([ "a_file.rb", "z_file.rb" ])
    end

    it "honors an explicit limit" do
      files = (1..5).to_h { |i| [ "file_#{i}.rb", { "lines_pct" => 0.0, "branches_pct" => 0.0 } ] }

      ranked = described_class.rank(files: files, change_frequency: {}, limit: 2)

      expect(ranked.size).to eq(2)
    end

    it "returns an empty array for an empty coverage report" do
      expect(described_class.rank(files: {}, change_frequency: {})).to eq([])
    end
  end
end
