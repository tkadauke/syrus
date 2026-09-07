require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe TargetGraph::NestedConfigDiscovery do
  around do |ex|
    Dir.mktmpdir("syrus-nested-config-discovery") { |dir| @dir = dir; ex.run }
  end

  describe ".call" do
    it "returns an empty array when there is no nested .syrus.yml at all" do
      write(".syrus.yml", "prepare: []\n")

      expect(described_class.call(@dir)).to eq([])
    end

    it "does not treat the root .syrus.yml as a nested declaration" do
      write(".syrus.yml", "prepare: []\n")

      expect(described_class.call(@dir)).to eq([])
    end

    it "discovers a .syrus.yml one directory below the root" do
      write("cli/.syrus.yml", "prepare: []\n")

      expect(described_class.call(@dir)).to eq([ "cli" ])
    end

    it "discovers .syrus.yml files nested several directories deep" do
      write("apps/desktop/.syrus.yml", "prepare: []\n")

      expect(described_class.call(@dir)).to eq([ "apps/desktop" ])
    end

    it "returns discovered directories sorted, regardless of filesystem iteration order" do
      write("zeta/.syrus.yml", "prepare: []\n")
      write("alpha/.syrus.yml", "prepare: []\n")
      write("mid/.syrus.yml", "prepare: []\n")

      expect(described_class.call(@dir)).to eq(%w[alpha mid zeta])
    end

    it "excludes .git, dependency/vendor caches, build outputs, and the .syrus scratch dir" do
      write(".git/.syrus.yml", "prepare: []\n")
      write("node_modules/some-pkg/.syrus.yml", "prepare: []\n")
      write("vendor/bundle/.syrus.yml", "prepare: []\n")
      write(".bundle/.syrus.yml", "prepare: []\n")
      write("tmp/.syrus.yml", "prepare: []\n")
      write("log/.syrus.yml", "prepare: []\n")
      write("coverage/.syrus.yml", "prepare: []\n")
      write("dist/.syrus.yml", "prepare: []\n")
      write("build/.syrus.yml", "prepare: []\n")
      write(".next/.syrus.yml", "prepare: []\n")
      write(".cache/.syrus.yml", "prepare: []\n")
      write(".syrus/workflows/1/.syrus.yml", "prepare: []\n")
      write("cli/.syrus.yml", "prepare: []\n")

      expect(described_class.call(@dir)).to eq([ "cli" ])
    end

    it "still discovers a legitimately nested .syrus.yml inside a directory that merely starts with an excluded name" do
      write("vendored-tools/.syrus.yml", "prepare: []\n")

      expect(described_class.call(@dir)).to eq([ "vendored-tools" ])
    end

    it "does not infer a project from package.json, go.mod, or other repository-structure signals" do
      write("cli/go.mod", "module example.com/cli\n")
      write("api/package.json", "{}\n")

      expect(described_class.call(@dir)).to eq([])
    end
  end

  def write(rel, contents)
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end
end
