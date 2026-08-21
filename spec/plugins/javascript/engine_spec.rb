require "rails_helper"
require "tmpdir"
require "json"
require "syrus/plugin/preview_provider"

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
          description:      "Node/JS (and TS) prepare detection and dev-server preview: yarn/pnpm/npm lockfile priority, package.json scripts.dev/start; ESLint grader detail; default `any`-type review criterion",
          homepage:         "https://github.com/tkadauke/syrus",
          prepare_priority: 20,
          provides: {
            prepare_detector:         JavaScript::PrepareDetector,
            preview_provider:         JavaScript::PreviewProvider,
            grader_augmentor:         JavaScript::EslintGraderAugmentor,
            review_criteria_provider: JavaScript::ReviewCriteriaProvider
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

    it "provides exactly the :prepare_detector, :preview_provider, :grader_augmentor, and :review_criteria_provider extension point keys" do
      expect(registration.provides.keys).to contain_exactly(
        :prepare_detector, :preview_provider, :grader_augmentor, :review_criteria_provider
      )
    end

    it "registers PrepareDetector as the :prepare_detector" do
      expect(registration.provides[:prepare_detector]).to eq(JavaScript::PrepareDetector)
    end

    it "registers PreviewProvider as the :preview_provider" do
      expect(registration.provides[:preview_provider]).to eq(JavaScript::PreviewProvider)
    end

    it "registers EslintGraderAugmentor as the :grader_augmentor" do
      expect(registration.provides[:grader_augmentor]).to eq(JavaScript::EslintGraderAugmentor)
    end

    it "registers ReviewCriteriaProvider as the :review_criteria_provider" do
      expect(registration.provides[:review_criteria_provider]).to eq(JavaScript::ReviewCriteriaProvider)
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

    describe ".shell_install_command" do
      it "renders the same PRIORITY table as a runtime if/elif shell chain" do
        expect(described_class.shell_install_command).to eq(
          "if [ -f yarn.lock ]; then yarn install --frozen-lockfile; " \
          "elif [ -f pnpm-lock.yaml ]; then pnpm install --frozen-lockfile; " \
          "elif [ -f package-lock.json ]; then npm ci; " \
          "elif [ -f package.json ]; then npm install; fi"
        )
      end
    end

    it "declares .node-version as its mise version file" do
      expect(described_class.mise_version_file).to eq(".node-version")
    end
  end

  describe JavaScript::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-javascript-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns [] for a repo with no recognized lockfile or package.json" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes the any-type criterion when a JS/TS project is detected" do
      write("package.json", "{}")

      expect(described_class.criteria(@dir)).to eq([ "Flag newly introduced `any` types" ])
    end
  end

  describe JavaScript::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-javascript-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns [] for a repo with no recognized lockfile or package.json" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes the any-type criterion when a JS/TS project is detected" do
      write("package.json", "{}")

      expect(described_class.criteria(@dir)).to eq([ "Flag newly introduced `any` types" ])
    end
  end

  describe JavaScript::PreviewProvider do
    subject(:provider) { described_class.new }

    around do |ex|
      Dir.mktmpdir("syrus-javascript-preview-provider") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def write_package_json(scripts)
      write("package.json", JSON.generate({ "scripts" => scripts }))
    end

    it "includes Syrus::Plugin::PreviewProvider" do
      expect(provider).to be_a(Syrus::Plugin::PreviewProvider)
    end

    describe "#detect?" do
      it "returns false when there is no package.json" do
        expect(provider.detect?(@dir)).to be false
      end

      it "returns false when package.json has neither dev nor start scripts" do
        write_package_json("build" => "vite build")

        expect(provider.detect?(@dir)).to be false
      end

      it "returns true when package.json has only scripts.dev" do
        write_package_json("dev" => "vite")

        expect(provider.detect?(@dir)).to be true
      end

      it "returns true when package.json has only scripts.start" do
        write_package_json("start" => "node server.js")

        expect(provider.detect?(@dir)).to be true
      end

      it "returns true when package.json has both scripts.dev and scripts.start" do
        write_package_json("dev" => "vite", "start" => "node server.js")

        expect(provider.detect?(@dir)).to be true
      end

      it "returns false for malformed package.json instead of raising" do
        write("package.json", "not json")

        expect(provider.detect?(@dir)).to be false
      end

      it "returns false when package.json has no scripts object" do
        write("package.json", "{}")

        expect(provider.detect?(@dir)).to be false
      end
    end

    describe "#start_command" do
      it "injects the port via PORT and defers dev/start selection to shell time" do
        expect(provider.start_command(port: 3001)).to eq(
          "PORT=3001 npm run $(node -e \"const s=(require('./package.json').scripts||{});" \
          "process.stdout.write(s.dev?'dev':'start')\")"
        )
      end

      it "interpolates the given port" do
        expect(provider.start_command(port: 4567)).to include("PORT=4567 npm run")
      end
    end

    describe "#setup_commands" do
      it "reuses JavaScript::PrepareDetector's lockfile branching" do
        expect(provider.setup_commands).to eq([ JavaScript::PrepareDetector.shell_install_command ])
      end
    end

    describe "interface defaults (no universal convention exists)" do
      it "defaults seed_command to nil" do
        expect(provider.seed_command).to be_nil
      end

      it "defaults health_check_path to /" do
        expect(provider.health_check_path).to eq("/")
      end

      it "defaults log_paths to empty" do
        expect(provider.log_paths).to eq([])
      end
    end
  end

  describe "PreviewCommandSource precedence" do
    around do |ex|
      Dir.mktmpdir("syrus-javascript-preview-precedence") { |dir| @dir = dir; ex.run }
    end

    before do
      Syrus::PluginRegistry.reset!
      Syrus::PluginRegistry.register(
        name:             "javascript",
        version:          JavaScript::VERSION,
        description:      "Node/JS (and TS) prepare detection and dev-server preview: yarn/pnpm/npm lockfile priority, package.json scripts.dev/start",
        homepage:         "https://github.com/tkadauke/syrus",
        prepare_priority: 20,
        provides: {
          prepare_detector: JavaScript::PrepareDetector,
          preview_provider: JavaScript::PreviewProvider
        }
      )
    end

    after { Syrus::PluginRegistry.reset! }

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "prefers an explicit .syrus.yml preview: section over the javascript plugin" do
      File.write(File.join(@dir, "package.json"), JSON.generate("scripts" => { "dev" => "vite" }))
      write(".syrus.yml", <<~YAML)
        preview:
          start: "node explicit-server.js --port $PORT"
      YAML

      result = PreviewCommandSource.new(@dir).resolve
      expect(result.start_command_for.call(port: 3005)).to eq("node explicit-server.js --port 3005")
    end

    it "falls back to the javascript plugin when .syrus.yml has no preview: section" do
      File.write(File.join(@dir, "package.json"), JSON.generate("scripts" => { "dev" => "vite" }))

      result = PreviewCommandSource.new(@dir).resolve
      expect(result).not_to be_nil
      expect(result.start_command_for.call(port: 3005)).to include("PORT=3005 npm run")
    end
  end
end
