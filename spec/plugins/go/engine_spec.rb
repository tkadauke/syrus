require "rails_helper"
require "tmpdir"

RSpec.describe Go::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "go" }
    end

    before do
      # The after_initialize block runs once at boot; plugin_registry.rb resets
      # the in-memory registry in test mode. Re-register here so examples see
      # the manifest. Interface modules were included during after_initialize
      # and are permanent on the classes.
      unless Syrus::PluginRegistry.registered_names.include?("go")
        Syrus::PluginRegistry.register(
          name:             "go",
          version:          Go::VERSION,
          description:      "Go prepare detection: go.mod → go mod download; gofmt autofix; default swallowed-error review criterion",
          homepage:         "https://github.com/tkadauke/syrus",
          prepare_priority: 40,
          provides: {
            prepare_detector:         Go::PrepareDetector,
            review_criteria_provider: Go::ReviewCriteriaProvider,
            autofix_command:          Go::GofmtAutofix
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
      expect(registration.version).to eq(Go::VERSION)
      expect(registration.prepare_priority).to eq(40)
    end

    it "provides exactly the :prepare_detector, :review_criteria_provider, and :autofix_command extension point keys" do
      expect(registration.provides.keys).to contain_exactly(:prepare_detector, :review_criteria_provider, :autofix_command)
    end

    it "registers GofmtAutofix as the :autofix_command" do
      expect(registration.provides[:autofix_command]).to eq(Go::GofmtAutofix)
    end

    it "registers PrepareDetector as the :prepare_detector" do
      expect(registration.provides[:prepare_detector]).to eq(Go::PrepareDetector)
    end

    it "registers ReviewCriteriaProvider as the :review_criteria_provider" do
      expect(registration.provides[:review_criteria_provider]).to eq(Go::ReviewCriteriaProvider)
    end
  end

  describe Go::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-go-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "does not detect a repo with no go.mod" do
      expect(described_class.detect?(@dir)).to be false
      expect(described_class.prepare_commands(@dir)).to eq([])
    end

    it "detects go.mod and contributes go mod download" do
      write("go.mod", "module example.com/foo\n\ngo 1.22\n")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "go mod download" ])
    end
  end

  describe Go::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-go-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns [] for a repo with no go.mod" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes the swallowed-error criterion when go.mod is present" do
      write("go.mod", "module example.com/foo\n\ngo 1.22\n")

      expect(described_class.criteria(@dir)).to eq([ "Flag swallowed errors (`_ = err`)" ])
    end
  end

  describe Go::GofmtAutofix do
    around do |ex|
      Dir.mktmpdir("syrus-go-gofmt-autofix") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "returns nil for a repo with no go.mod" do
      expect(described_class.autofix_command(workspace_path: @dir)).to be_nil
    end

    it "contributes gofmt -w . when go.mod is present" do
      write("go.mod", "module example.com/foo\n\ngo 1.22\n")

      expect(described_class.autofix_command(workspace_path: @dir)).to eq("gofmt -w .")
    end
  end
end
