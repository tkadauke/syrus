require "rails_helper"
require "tmpdir"

RSpec.describe "SyrusRails.detect?" do
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
