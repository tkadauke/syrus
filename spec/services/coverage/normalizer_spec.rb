require "rails_helper"

RSpec.describe Coverage::Normalizer do
  let(:raw) do
    {
      files: {
        "app/models/user.rb" => {
          lines: { 1 => 3, 2 => 0, 5 => 1 },
          branches: { hit: 4, found: 6 },
          functions: nil
        },
        "app/models/post.rb" => {
          lines: { 1 => 1, 2 => 1 },
          branches: nil,
          functions: nil
        }
      }
    }
  end

  describe "#normalize" do
    it "computes overall lines_pct across all files" do
      result = described_class.new(raw).normalize
      # user.rb: 2/3 covered; post.rb: 2/2 covered → 4/5 total = 80%
      expect(result[:summary][:lines_pct]).to eq(80.0)
    end

    it "includes covered_lines and total_lines in the summary" do
      result = described_class.new(raw).normalize
      expect(result[:summary][:covered_lines]).to eq(4)
      expect(result[:summary][:total_lines]).to eq(5)
    end

    it "computes per-file lines_pct" do
      result = described_class.new(raw).normalize

      expect(result[:files]["app/models/user.rb"][:lines_pct]).to be_within(0.01).of(66.67)
      expect(result[:files]["app/models/post.rb"][:lines_pct]).to eq(100.0)
    end

    it "computes per-file branches_pct when branch data is available" do
      result = described_class.new(raw).normalize

      expect(result[:files]["app/models/user.rb"][:branches_pct]).to be_within(0.01).of(66.67)
    end

    it "returns nil branches_pct when branch data is absent" do
      result = described_class.new(raw).normalize

      expect(result[:files]["app/models/post.rb"][:branches_pct]).to be_nil
    end

    it "builds the hit_map with string-keyed line numbers" do
      result = described_class.new(raw).normalize

      expect(result[:hit_map]["app/models/user.rb"]).to eq("1" => 3, "2" => 0, "5" => 1)
      expect(result[:hit_map]["app/models/post.rb"]).to eq("1" => 1, "2" => 1)
    end

    it "handles a file with zero executable lines" do
      raw_with_empty = { files: { "app/models/empty.rb" => { lines: {}, branches: nil, functions: nil } } }
      result = described_class.new(raw_with_empty).normalize

      expect(result[:files]["app/models/empty.rb"][:lines_pct]).to be_nil
      expect(result[:summary][:lines_pct]).to be_nil
    end

    it "returns nil lines_pct in summary when there are no files" do
      result = described_class.new(files: {}).normalize

      expect(result[:summary][:lines_pct]).to be_nil
      expect(result[:files]).to eq({})
      expect(result[:hit_map]).to eq({})
    end

    it "handles branches with zero found gracefully" do
      raw_zero = {
        files: {
          "app/foo.rb" => {
            lines: { 1 => 1 },
            branches: { hit: 0, found: 0 },
            functions: nil
          }
        }
      }
      result = described_class.new(raw_zero).normalize

      expect(result[:files]["app/foo.rb"][:branches_pct]).to be_nil
    end
  end
end
