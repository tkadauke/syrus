require "rails_helper"
require "tmpdir"

RSpec.describe Go::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "go" }
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata" do
      expect(registration.version).to eq(Syrus::PluginApi.default_version)
      expect(registration.prepare_priority).to eq(40)
      expect(registration.category).to eq("language")
    end

    it "registers its Ecosystem providers and none of the absorbed legacy points" do
      expect(registration.provides).to be_empty
      expect(registration.family_provides.map { |entry| [ entry.provider, entry.capabilities ] }).to contain_exactly(
        [ "Go::Ecosystem", %i[detect_prepare review_criteria autofix dependency_audit analyze_coverage] ],
        [ "Go::TestEcosystem", %i[grader_types] ]
      )
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

    it "detects go.mod and contributes GOWORK=off go mod download" do
      write("go.mod", "module example.com/foo\n\ngo 1.22\n")

      expect(described_class.detect?(@dir)).to be true
      expect(described_class.prepare_commands(@dir)).to eq([ "GOWORK=off go mod download" ])
    end

    it "declares .go-version as its mise version file" do
      expect(described_class.mise_version_file).to eq(".go-version")
    end

    it "detects go.mod regardless of its content, since presence alone is the signal" do
      write("go.mod", "")

      expect(described_class.detect?(@dir)).to be true
    end

    describe ".span_labels" do
      it "labels go test, go vet, and go build command spans for worker-health diagnostics" do
        labels = described_class.span_labels

        expect(labels.find { |(pattern, _)| pattern.match?("go test ./...") }.last).to eq("go test")
        expect(labels.find { |(pattern, _)| pattern.match?("go vet ./...") }.last).to eq("go vet")
        expect(labels.find { |(pattern, _)| pattern.match?("go build -o bin/app .") }.last).to eq("go build")
      end

      it "does not match unrelated commands" do
        labels = described_class.span_labels

        expect(labels.any? { |(pattern, _)| pattern.match?("gofmt -w .") }).to be false
      end
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
      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "main.go" ])).to be_nil
    end

    it "contributes gofmt -w . when go.mod is present" do
      write("go.mod", "module example.com/foo\n\ngo 1.22\n")

      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "main.go", "README.md" ])).to eq("gofmt -w main.go")
    end
  end
end
