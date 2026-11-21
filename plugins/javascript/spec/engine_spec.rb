require "rails_helper"
require "tmpdir"
require "json"
require "syrus/plugin/preview_provider"

RSpec.describe JavaScript::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "javascript" }
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata" do
      expect(registration.version).to eq(Syrus::PluginApi.default_version)
      expect(registration.prepare_priority).to eq(20)
      expect(registration.category).to eq("language")
    end

    it "registers its Ecosystem providers and none of the absorbed legacy points" do
      expect(registration.provides.keys).to contain_exactly(:preview_provider)
      expect(registration.family_provides.map { |entry| [ entry.provider, entry.capabilities ] }).to contain_exactly(
        [ "JavaScript::Ecosystem", %i[detect_prepare grade_candidates grader_diagnostics review_criteria autofix dependency_audit focused_tests] ],
        [ "JavaScript::PrettierEcosystem", %i[autofix] ],
        [ "JavaScript::VitestEcosystem", %i[grader_types] ]
      )
    end

    it "registers PreviewProvider as the :preview_provider" do
      expect(registration.provides[:preview_provider]).to eq(JavaScript::PreviewProvider)
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
    describe ".shell_fresh_install_command" do
      {
        "yarn.lock" => "yarn install --frozen-lockfile",
        "pnpm-lock.yaml" => "pnpm install --frozen-lockfile",
        "package-lock.json" => "npm ci",
        "package.json" => "npm install"
      }.each do |lockfile, expected|
        it "installs with #{expected} when #{lockfile} is present" do
          write(lockfile, "{}")
          shell_stubs = 'yarn() { echo "yarn $*"; }; pnpm() { echo "pnpm $*"; }; npm() { echo "npm $*"; };'
          output, status = Open3.capture2("bash", "-c", "#{shell_stubs} #{described_class.shell_fresh_install_command}", chdir: @dir)

          expect(status).to be_success
          expect(output.strip).to eq(expected)
        end
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

  describe JavaScript::EslintAutofix do
    around do |ex|
      Dir.mktmpdir("syrus-javascript-eslint-autofix") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns nil for a repo with no ESLint config file" do
      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "src/app.ts" ])).to be_nil
    end

    it "contributes the fix command when a flat eslint.config.js is present" do
      write("eslint.config.js")

      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "src/app.ts", "README.md" ])).to eq("npx eslint --fix -- src/app.ts")
    end

    it "contributes the fix command when a legacy .eslintrc.json is present" do
      write(".eslintrc.json", "{}")

      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "src/app.js" ])).to eq("npx eslint --fix -- src/app.js")
    end
  end

  describe JavaScript::PrettierAutofix do
    around do |ex|
      Dir.mktmpdir("syrus-javascript-prettier-autofix") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns nil for a repo with no Prettier config" do
      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "src/app.ts" ])).to be_nil
    end

    it "contributes the write command when a .prettierrc is present" do
      write(".prettierrc", "{}")

      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "src/app.ts" ])).to eq("npx prettier --write --ignore-unknown -- src/app.ts")
    end

    it "contributes the write command when package.json declares a prettier key" do
      write("package.json", JSON.generate("prettier" => { "singleQuote" => true }))

      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "src/app.ts" ])).to eq("npx prettier --write --ignore-unknown -- src/app.ts")
    end

    it "returns nil for malformed package.json instead of raising" do
      write("package.json", "not json")

      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "src/app.ts" ])).to be_nil
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

      it "returns false for a Rails repo with a package dev script" do
        write_package_json("dev" => "vite")
        write("Gemfile", "")
        write("config/application.rb", "")
        write("bin/rails", "")

        expect(provider.detect?(@dir)).to be false
      end

      it "returns false for a Django repo with a package start script" do
        write_package_json("start" => "vite --host 0.0.0.0")
        write("manage.py", "os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'project.settings')")
        write("project/settings.py", "")

        expect(provider.detect?(@dir)).to be false
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
        version:          Syrus::PluginApi.default_version,
        description:      "Node/JS (and TS) prepare detection and dev-server preview: yarn/pnpm/npm lockfile priority, package.json scripts.dev/start",
        homepage:         "https://github.com/tkadauke/syrus",
        prepare_priority: 20,
        provides: {
          preview_provider: JavaScript::PreviewProvider
        }
      )
      Syrus::PluginRegistry.register(
        name:             "ruby",
        version:          Syrus::PluginApi.default_version,
        description:      "Ruby language support.",
        prepare_priority: 10,
        provides:         {}
      )
      Syrus::PluginRegistry.register(
        name:             "python",
        version:          Syrus::PluginApi.default_version,
        description:      "Python language support.",
        prepare_priority: 30,
        provides:         {}
      )
      Syrus::PluginRegistry.register(
        name:             "syrus-rails",
        version:          Syrus::PluginApi.default_version,
        description:      "Ruby on Rails framework intelligence.",
        depends_on:       [ "ruby" ],
        provides:         { preview_provider: SyrusRails::PreviewProvider }
      )
      Syrus::PluginRegistry.register(
        name:             "django",
        version:          Syrus::PluginApi.default_version,
        description:      "Django framework intelligence.",
        depends_on:       [ "python" ],
        provides:         { preview_provider: Django::PreviewProvider }
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

    it "uses the Rails preview provider for a Rails repo with a package dev script" do
      write("package.json", JSON.generate("scripts" => { "dev" => "vite" }))
      write("Gemfile", "")
      write("config/application.rb", "")
      write("bin/rails", "")

      result = PreviewCommandSource.new(@dir).resolve
      expect(result).not_to be_nil
      expect(result.start_command_for.call(port: 3005)).to include("bin/rails server -p 3005")
      expect(result.seed_command).to eq("bin/rails db:create db:migrate db:seed")
    end

    it "uses the Django preview provider for a Django repo with a package start script" do
      write("package.json", JSON.generate("scripts" => { "start" => "vite --host 0.0.0.0" }))
      write("manage.py", "os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'project.settings')")
      write("project/settings.py", "")

      result = PreviewCommandSource.new(@dir).resolve
      expect(result).not_to be_nil
      expect(result.start_command_for.call(port: 3005)).to include("python manage.py runserver 0.0.0.0:3005")
      expect(result.seed_command).to include("python manage.py migrate")
    end
  end
end
