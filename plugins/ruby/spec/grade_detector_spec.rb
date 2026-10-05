require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Ruby::GradeDetector do
  it "detects RSpec before Minitest in mixed repositories" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "spec"))
      FileUtils.mkdir_p(File.join(dir, "test/models"))
      File.write(File.join(dir, "test/models/widget_test.rb"), "require 'minitest/autorun'\n")

      expect(described_class.grade_candidates(dir)).to eq([
        {
          name: "rspec",
          run: "type: rspec",
          type: "rspec",
          evidence: "spec/"
        }
      ])
    end
  end

  it "detects conventional Minitest test layouts" do
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "test/models"))
      File.write(File.join(dir, "test/test_helper.rb"), "require 'minitest/autorun'\n")
      File.write(File.join(dir, "test/models/widget_test.rb"), "require_relative '../test_helper'\n")

      expect(described_class.grade_candidates(dir)).to eq([
        {
          name: "minitest",
          run: "type: minitest",
          type: "minitest",
          evidence: "test/test_helper.rb"
        }
      ])
    end
  end

  it "detects Minitest when the Gemfile declares it" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), "gem 'minitest'\n")

      expect(described_class.grade_candidates(dir)).to eq([
        {
          name: "minitest",
          run: "type: minitest",
          type: "minitest",
          evidence: "Gemfile minitest dependency"
        }
      ])
    end
  end
end
