require "rails_helper"

RSpec.describe Coverage::MergeStrategy do
  let(:raw_a) do
    {
      files: {
        "app/models/user.rb" => {
          lines: { 1 => 0, 2 => 3, 5 => 0 },
          branches: { hit: 4, found: 8 },
          functions: { hit: 2, found: 3 }
        },
        "app/models/post.rb" => {
          lines: { 1 => 1, 2 => 0 },
          branches: nil,
          functions: nil
        }
      }
    }
  end

  let(:raw_b) do
    {
      files: {
        "app/models/user.rb" => {
          lines: { 1 => 2, 3 => 1, 5 => 0 },
          branches: { hit: 2, found: 4 },
          functions: { hit: 1, found: 2 }
        },
        "app/models/comment.rb" => {
          lines: { 1 => 5 },
          branches: nil,
          functions: nil
        }
      }
    }
  end

  describe ".merge" do
    it "takes the maximum hit count for lines present in both files" do
      result = described_class.merge(raw_a, raw_b)
      user = result[:files]["app/models/user.rb"]

      expect(user[:lines][1]).to eq(2)  # max(0, 2)
      expect(user[:lines][2]).to eq(3)  # only in a
      expect(user[:lines][5]).to eq(0)  # max(0, 0)
    end

    it "includes lines present in only one source" do
      result = described_class.merge(raw_a, raw_b)
      user = result[:files]["app/models/user.rb"]

      expect(user[:lines]).to have_key(2)  # only in raw_a
      expect(user[:lines]).to have_key(3)  # only in raw_b
    end

    it "adds branch counts from both sources" do
      result = described_class.merge(raw_a, raw_b)
      user = result[:files]["app/models/user.rb"]

      expect(user[:branches]).to eq(hit: 6, found: 12)
    end

    it "adds function counts from both sources" do
      result = described_class.merge(raw_a, raw_b)
      user = result[:files]["app/models/user.rb"]

      expect(user[:functions]).to eq(hit: 3, found: 5)
    end

    it "includes files present in only one source unchanged" do
      result = described_class.merge(raw_a, raw_b)

      expect(result[:files]).to have_key("app/models/post.rb")
      expect(result[:files]).to have_key("app/models/comment.rb")
      expect(result[:files]["app/models/comment.rb"][:lines]).to eq(1 => 5)
    end

    it "preserves nil branches when only one source has the file" do
      result = described_class.merge(raw_a, raw_b)

      expect(result[:files]["app/models/post.rb"][:branches]).to be_nil
    end

    it "returns nil branches when both sources have nil branches" do
      result = described_class.merge(raw_a, raw_b)

      post = result[:files]["app/models/post.rb"]
      comment = result[:files]["app/models/comment.rb"]
      expect(post[:branches]).to be_nil
      expect(comment[:branches]).to be_nil
    end
  end

  describe ".merge_all" do
    it "returns empty files for an empty array" do
      expect(described_class.merge_all([])).to eq(files: {})
    end

    it "returns the single element unchanged for a one-element array" do
      result = described_class.merge_all([raw_a])
      expect(result[:files].keys).to match_array(raw_a[:files].keys)
    end

    it "chains multiple merges together" do
      raw_c = {
        files: {
          "app/models/user.rb" => {
            lines: { 1 => 10 },
            branches: { hit: 1, found: 1 },
            functions: nil
          }
        }
      }

      result = described_class.merge_all([raw_a, raw_b, raw_c])
      user = result[:files]["app/models/user.rb"]

      expect(user[:lines][1]).to eq(10)  # max(max(0,2), 10)
      expect(user[:branches]).to eq(hit: 7, found: 13)  # (4+2)+1
    end
  end
end
