require "rails_helper"

RSpec.describe WorkspaceDependencyEnv do
  describe ".for" do
    around do |example|
      Dir.mktmpdir do |dir|
        @tmpdir = dir
        example.run
      end
    end

    it "returns a hash with all expected env var keys" do
      result = described_class.for(@tmpdir)

      expect(result.keys).to contain_exactly(
        "BUNDLE_PATH",
        "BUNDLE_APP_CONFIG",
        "BUNDLE_USER_HOME",
        "BUNDLE_USER_CACHE",
        "NPM_CONFIG_CACHE",
        "YARN_CACHE_FOLDER",
        "COREPACK_HOME"
      )
    end

    it "scopes all paths under <workspace>/.syrus/deps" do
      result = described_class.for(@tmpdir)
      deps_root = File.join(@tmpdir, ".syrus", "deps")

      result.each_value do |path|
        expect(path).to start_with(deps_root)
      end
    end

    it "creates the deps directory if it does not exist" do
      described_class.for(@tmpdir)

      expect(File.directory?(File.join(@tmpdir, ".syrus", "deps"))).to be true
    end

    it "returns string values, not Pathname objects" do
      result = described_class.for(@tmpdir)

      result.each_value do |value|
        expect(value).to be_a(String)
      end
    end

    it "uses distinct paths for each tool" do
      result = described_class.for(@tmpdir)
      values = result.values

      expect(values.uniq.length).to eq(values.length)
    end
  end
end
