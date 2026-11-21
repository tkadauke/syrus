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
      expect(result.error?).to be(false)
    end

    it "treats prepare: false as opt-out" do
      write(".syrus.yml", "prepare: false\n")
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/opted out/)
      expect(result.error?).to be(false)
    end

    it "treats unexpected prepare: types as explicit config errors" do
      write(".syrus.yml", "prepare: bundle install\n")  # string, not array
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/must be an array/)
      expect(result.error).to match(/must be an array/)
      expect(result.error?).to be(true)
    end

    it "doesn't fall back to auto-detect when .syrus.yml exists but has no prepare key" do
      write(".syrus.yml", "other_setting: 42\n")
      write("Gemfile", "")
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.source).to eq(".syrus.yml")
    end

    it "captures parse errors as explicit config errors" do
      write(".syrus.yml", "prepare:\n  - bundle install\n  -\nbroken: [\n")
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/YAML parse error/)
      expect(result.error).to match(/YAML parse error/)
      expect(result.error?).to be(true)
    end
  end

  describe "auto-detect", requires_plugin: %w[ruby javascript] do
    # RepoPrepPlan no longer hardcodes Ruby/Node signals — it delegates
    # entirely to registered Ecosystem providers. Register the real
    # bundled `ruby` and `javascript` plugins (mirroring their engine.rb
    # manifests) so these specs exercise the actual production wiring
    # instead of a RepoPrepPlan-local fixture.
    before do
      unless Syrus::PluginRegistry.registered_names.include?("ruby")
        Syrus::PluginRegistry.register(
          name: "ruby", version: Syrus::PluginApi.default_version, prepare_priority: 10,
          family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
            family: :ecosystem, provider: "Ruby::Ecosystem", implements: %i[detect_prepare]
          ) ]
        )
      end

      unless Syrus::PluginRegistry.registered_names.include?("javascript")
        Syrus::PluginRegistry.register(
          name: "javascript", version: Syrus::PluginApi.default_version, prepare_priority: 20,
          family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
            family: :ecosystem, provider: "JavaScript::Ecosystem", implements: %i[detect_prepare]
          ) ]
        )
      end
    end

    after { Syrus::PluginRegistry.reset! }

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
      expect(result.source).to include("Ruby")
      expect(result.source).to include("JavaScript")
    end

    it "no recognized signals → empty + diagnostic" do
      result = described_class.for(@dir)
      expect(result.commands).to be_empty
      expect(result.note).to match(/no recognized signals/)
    end
  end

  describe "Ecosystem prepare providers", :reset_plugin_registry do
    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    def register_detector(plugin_name:, file:, command:, prepare_priority: 100)
      detector = Class.new do
        def self.key = :fixture
        def self.display_name = name
      end
      detector.define_singleton_method(:name) { plugin_name.to_s.capitalize + "PrepareDetector" }
      detector.define_singleton_method(:detect_prepare) do |context|
        next [] unless File.exist?(File.join(context.repo_path, file))
        [ Syrus::Host::EcosystemPreparePlan.new(detected: true, commands: [ command ], label: name) ]
      end

      register_ecosystem_provider(name: plugin_name, provider: detector,
        implements: %i[detect_prepare], prepare_priority:)
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

    it "deduplicates identical commands from layered language plugins while keeping detector labels" do
      register_detector(plugin_name: "test_java", file: "build.gradle.kts", command: "gradle --no-daemon testClasses", prepare_priority: 45)
      register_detector(plugin_name: "test_kotlin", file: "build.gradle.kts", command: "gradle --no-daemon testClasses", prepare_priority: 46)
      write("build.gradle.kts", "")

      result = described_class.for(@dir)

      expect(result.commands).to eq([ "gradle --no-daemon testClasses" ])
      expect(result.source).to eq("auto-detect (Test_javaPrepareDetector, Test_kotlinPrepareDetector)")
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
  end
end
