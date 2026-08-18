require "rails_helper"
require "tmpdir"

RSpec.describe RepoPrepPlan do
  around do |ex|
    Dir.mktmpdir("syrus-repo-prep") { |dir| @dir = dir; ex.run }
  end

  def write(rel, contents = "")
    path = File.join(@dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
  end

  describe ".syrus.yml" do
    it "uses prepare: list verbatim" do
      write(".syrus.yml", <<~YAML)
        prepare:
          - bundle install --jobs 4
          - npm ci
      YAML
      result = described_class.for(@dir)
      expect(result.commands).to eq([ "bundle install --jobs 4", "npm ci" ])
      expect(result.source).to eq(".syrus.yml")
      expect(result.guessed?).to be(false)
    end

    it "treats prepare: [] as explicit no-op" do
      write(".syrus.yml", "prepare: []\n")
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/no commands/)
    end

    it "treats prepare: false as opt-out" do
      write(".syrus.yml", "prepare: false\n")
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/opted out/)
    end

    it "treats unexpected prepare: types as no-op (with diagnostic)" do
      write(".syrus.yml", "prepare: bundle install\n")  # string, not array
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/must be an array/)
    end

    it "doesn't fall back to auto-detect when .syrus.yml exists but has no prepare key" do
      write(".syrus.yml", "other_setting: 42\n")
      write("Gemfile", "")
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.source).to eq(".syrus.yml")
    end

    it "captures parse errors without raising" do
      write(".syrus.yml", "prepare:\n  - bundle install\n  -\nbroken: [\n")
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/YAML parse error/)
    end
  end

  describe "auto-detect" do
    it "Gemfile → bundle install" do
      write("Gemfile", "")
      result = described_class.for(@dir)
      expect(result.commands).to eq([ "bundle install" ])
      # Auto-detected plans are guesses — Steps::Prepare soft-fails them.
      expect(result.guessed?).to be(true)
    end

    it "yarn.lock wins over package.json + package-lock.json" do
      write("package.json", "{}")
      write("package-lock.json", "{}")
      write("yarn.lock", "")
      expect(described_class.for(@dir).commands).to eq([ "yarn install --frozen-lockfile" ])
    end

    it "pnpm-lock.yaml wins over package-lock.json" do
      write("package-lock.json", "{}")
      write("pnpm-lock.yaml", "")
      expect(described_class.for(@dir).commands).to eq([ "pnpm install --frozen-lockfile" ])
    end

    it "package-lock.json → npm ci" do
      write("package.json", "{}")
      write("package-lock.json", "{}")
      expect(described_class.for(@dir).commands).to eq([ "npm ci" ])
    end

    it "bare package.json → npm install" do
      write("package.json", "{}")
      expect(described_class.for(@dir).commands).to eq([ "npm install" ])
    end

    it "Gemfile + Node lockfile → both, unioned across ecosystems (no double-install within Node)" do
      write("Gemfile", "")
      write("package.json", "{}")
      write("package-lock.json", "{}")
      write("yarn.lock", "")
      result = described_class.for(@dir)
      expect(result.commands).to eq([ "bundle install", "yarn install --frozen-lockfile" ])
      expect(result.source).to include("Gemfile")
      expect(result.source).to include("yarn.lock")
    end

    it "no recognized signals → empty + diagnostic" do
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/no recognized signals/)
    end
  end

  describe ":prepare_detector plugins", :reset_plugin_registry do
    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    def register_detector(plugin_name:, file:, command:, prepare_priority: 100)
      detector = Class.new do
        include Syrus::Plugin::PrepareDetector
      end
      detector.define_singleton_method(:name) { plugin_name.to_s.capitalize + "PrepareDetector" }
      detector.define_singleton_method(:detect?) { |repo_path| File.exist?(File.join(repo_path, file)) }
      detector.define_singleton_method(:prepare_commands) { |_repo_path| [ command ] }

      Syrus::PluginRegistry.register(
        name: plugin_name, version: "1.0.0", prepare_priority: prepare_priority,
        provides: { prepare_detector: detector }
      )
      detector
    end

    it "unions commands from every matching plugin" do
      register_detector(plugin_name: "test_python", file: "requirements.txt", command: "pip install -r requirements.txt")
      register_detector(plugin_name: "test_go", file: "go.mod", command: "go mod download")
      write("requirements.txt", "")
      write("go.mod", "")

      result = described_class.for(@dir)
      expect(result.commands).to contain_exactly("pip install -r requirements.txt", "go mod download")
      expect(result.guessed?).to be(true)
    end

    it "a single matching plugin behaves like today's single-command output" do
      register_detector(plugin_name: "test_python", file: "requirements.txt", command: "pip install -r requirements.txt")
      write("requirements.txt", "")

      result = described_class.for(@dir)
      expect(result.commands).to eq([ "pip install -r requirements.txt" ])
    end

    it "orders commands by prepare_priority, lower first, regardless of registration order" do
      register_detector(plugin_name: "test_low_priority", file: "low.marker", command: "run low", prepare_priority: 200)
      register_detector(plugin_name: "test_high_priority", file: "high.marker", command: "run high", prepare_priority: 10)
      write("low.marker", "")
      write("high.marker", "")

      result = described_class.for(@dir)
      expect(result.commands).to eq([ "run high", "run low" ])
    end

    it "excludes plugins the operator has disabled" do
      register_detector(plugin_name: "test_disabled", file: "disabled.marker", command: "should not run")
      write("disabled.marker", "")
      PluginRecord.find_by!(name: "test_disabled").update!(enabled: false)

      result = described_class.for(@dir)
      expect(result.commands).to be_empty
    end

    it "still unions with the legacy Ruby/Node fallback" do
      register_detector(plugin_name: "test_python", file: "requirements.txt", command: "pip install -r requirements.txt")
      write("requirements.txt", "")
      write("Gemfile", "")

      result = described_class.for(@dir)
      expect(result.commands).to contain_exactly("pip install -r requirements.txt", "bundle install")
    end
  end
end
