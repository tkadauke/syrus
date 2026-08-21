require "rails_helper"
require "tmpdir"

RSpec.describe JavaScript::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "javascript" }
    end

    before do
      # The after_initialize block runs once at boot; plugin_registry.rb resets
      # the in-memory registry in test mode. Re-register here so examples see
      # the manifest. Interface modules were included during after_initialize
      # and are permanent on the classes.
      unless Syrus::PluginRegistry.registered_names.include?("javascript")
        Syrus::PluginRegistry.register(
          name:             "javascript",
          version:          JavaScript::VERSION,
          description:      "Node/JS (and TS) prepare detection: yarn/pnpm/npm lockfile priority",
          homepage:         "https://github.com/tkadauke/syrus",
          prepare_priority: 20,
          provides: {
            prepare_detector: JavaScript::PrepareDetector
          }
        )
      end
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata" do
      expect(registration.version).to eq(JavaScript::VERSION)
      expect(registration.prepare_priority).to eq(20)
    end

    it "provides exactly the :prepare_detector extension point key" do
      expect(registration.provides.keys).to contain_exactly(:prepare_detector)
    end

    it "registers PrepareDetector as the :prepare_detector" do
      expect(registration.provides[:prepare_detector]).to eq(JavaScript::PrepareDetector)
    end
  end

  describe JavaScript::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-javascript-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "does not detect a repo with no recognized lockfile" do
      expect(described_class.detect?(@dir)).to be false
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "yarn.lock wins over pnpm-lock.yaml, package-lock.json, and package.json" do
      write("package.json", "{}")
      write("package-lock.json", "{}")
      write("pnpm-lock.yaml", "")
      write("yarn.lock", "")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "yarn install --frozen-lockfile" ])
    end

    it "pnpm-lock.yaml wins over package-lock.json and package.json" do
      write("package.json", "{}")
      write("package-lock.json", "{}")
      write("pnpm-lock.yaml", "")

      expect(described_class.prepare_commands(@dir)).to eq([ "pnpm install --frozen-lockfile" ])
    end

    it "package-lock.json wins over bare package.json" do
      write("package.json", "{}")
      write("package-lock.json", "{}")

      expect(described_class.prepare_commands(@dir)).to eq([ "npm ci" ])
    end

    it "bare package.json → npm install" do
      write("package.json", "{}")

      expect(described_class.prepare_commands(@dir)).to eq([ "npm install" ])
    end
  end
end
