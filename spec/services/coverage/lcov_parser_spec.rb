require "rails_helper"

RSpec.describe Coverage::LcovParser do
  def fixture(name)
    Rails.root.join("spec/fixtures/coverage/#{name}").read
  end

  describe "#parse" do
    it "parses line data from a valid LCOV fixture" do
      result = described_class.new(fixture("sample.lcov")).parse

      user = result[:files]["app/models/user.rb"]
      expect(user[:lines]).to eq(1 => 3, 2 => 0, 5 => 1, 10 => 2)
    end

    it "parses branch counts when present" do
      result = described_class.new(fixture("sample.lcov")).parse

      user = result[:files]["app/models/user.rb"]
      expect(user[:branches]).to eq(hit: 12, found: 16)
    end

    it "parses function counts when present" do
      result = described_class.new(fixture("sample.lcov")).parse

      user = result[:files]["app/models/user.rb"]
      expect(user[:functions]).to eq(hit: 8, found: 9)
    end

    it "returns nil branches when BRH/BRF are absent" do
      result = described_class.new(fixture("sample.lcov")).parse

      post = result[:files]["app/models/post.rb"]
      expect(post[:branches]).to be_nil
      expect(post[:functions]).to be_nil
    end

    it "handles empty file sections (no DA records)" do
      result = described_class.new(fixture("sample.lcov")).parse

      comment = result[:files]["app/models/comment.rb"]
      expect(comment[:lines]).to eq({})
      expect(comment[:branches]).to be_nil
    end

    it "includes all source files from the fixture" do
      result = described_class.new(fixture("sample.lcov")).parse

      expect(result[:files].keys).to contain_exactly(
        "app/models/user.rb",
        "app/controllers/users_controller.rb",
        "app/models/post.rb",
        "app/models/comment.rb"
      )
    end

    it "strips an absolute workspace prefix from paths" do
      content = "SF:/workspace/project/app/models/user.rb\nDA:1,3\nend_of_record\n"
      result = described_class.new(content, workspace: "/workspace/project").parse

      expect(result[:files].keys).to eq(["app/models/user.rb"])
    end

    it "normalises the workspace prefix regardless of trailing slash" do
      content = "SF:/srv/app/models/user.rb\nDA:1,1\nend_of_record\n"
      result = described_class.new(content, workspace: "/srv/").parse

      expect(result[:files].keys).to eq(["app/models/user.rb"])
    end

    it "leaves paths unchanged when they do not start with the workspace prefix" do
      content = "SF:app/models/user.rb\nDA:1,1\nend_of_record\n"
      result = described_class.new(content, workspace: "/some/other/path").parse

      expect(result[:files].keys).to eq(["app/models/user.rb"])
    end

    it "returns empty files hash for empty input" do
      expect(described_class.new("").parse).to eq(files: {})
    end

    it "ignores malformed DA lines and parses valid ones" do
      content = "SF:app/models/foo.rb\nDA:bad,data\nDA:1,3\nend_of_record\n"
      result = described_class.new(content).parse

      expect(result[:files]["app/models/foo.rb"][:lines]).to eq(1 => 3)
    end

    it "ignores records outside of an SF/end_of_record block" do
      content = "DA:1,99\nBRH:5\nend_of_record\n"
      result = described_class.new(content).parse

      expect(result[:files]).to be_empty
    end
  end
end
