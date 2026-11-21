require "rails_helper"
require "tmpdir"

RSpec.describe Ruby::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "ruby" }
    end

    after do
      Syrus::PluginRegistry.reset!
    end

    it "registers itself with Syrus::PluginRegistry" do
      expect(registration).not_to be_nil
    end

    it "registers with the correct metadata" do
      expect(registration.version).to eq(Syrus::PluginApi.default_version)
      expect(registration.prepare_priority).to eq(10)
      expect(registration.category).to eq("language")
    end

    it "registers its Ecosystem providers and none of the absorbed legacy points" do
      expect(registration.provides.keys).to contain_exactly("test_insights:parser")
      expect(registration.family_provides.map { |entry| [ entry.provider, entry.capabilities ] }).to contain_exactly(
        [ "Ruby::Ecosystem", %i[detect_prepare grade_candidates grader_diagnostics review_criteria autofix dependency_audit focused_tests analyze_coverage affected_tests] ],
        [ "Ruby::RspecEcosystem", %i[grader_types] ],
        [ "Ruby::MinitestEcosystem", %i[grader_types] ]
      )
    end

    # The parser point is hosted by test_insights, not core: the plugin that
    # ingests results owns the interface for parsing them.
    it "registers RspecParser into the test_insights parser point" do
      expect(registration.provides["test_insights:parser"]).to eq(Ruby::RspecParser)
      expect(Syrus::PluginRegistry.providers_for("test_insights:parser")).to include(Ruby::RspecParser)
    end

    it "leaves RSpec augmentor behavior unaffected by RubocopGraderAugmentor being registered alongside it" do
      Dir.mktmpdir("syrus-ruby-augmentors") do |dir|
        workspace_path = Pathname.new(dir)
        rspec_dir = workspace_path.join(".syrus/rspec-json")
        FileUtils.mkdir_p(rspec_dir)
        rspec_dir.join("worker-0.json").write(JSON.generate(
          "examples" => [ { "status" => "failed", "full_description" => "still works" } ]
        ))

        lines = Ruby::GraderAugmentor.augment_grader_failure(
          name: "rspec", command: "bin/rspec", workspace_path: workspace_path
        )

        expect(lines).to include("still works\n")
      end
    end
  end

  describe Ruby::PrepareDetector do
    around do |ex|
      Dir.mktmpdir("syrus-ruby-prepare-detector") { |dir| @dir = dir; ex.run }
    end

    it "detects a Gemfile at the repo root" do
      FileUtils.touch(File.join(@dir, "Gemfile"))
      expect(described_class.detect?(@dir)).to be true
    end

    it "does not detect a repo without a Gemfile" do
      expect(described_class.detect?(@dir)).to be false
    end

    it "contributes bundle install" do
      expect(described_class.prepare_commands(@dir)).to eq([ "bundle install" ])
    end

    it "declares .ruby-version as its mise version file" do
      expect(described_class.mise_version_file).to eq(".ruby-version")
    end
  end

  describe Ruby::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-ruby-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    it "returns [] for a repo with no Gemfile" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes the N+1 criterion when a Gemfile is present" do
      FileUtils.touch(File.join(@dir, "Gemfile"))

      expect(described_class.criteria(@dir)).to eq([ "Flag new N+1 query patterns in ActiveRecord code" ])
    end
  end

  describe Ruby::RubocopAutofix do
    around do |ex|
      Dir.mktmpdir("syrus-ruby-rubocop-autofix") { |dir| @dir = dir; ex.run }
    end

    it "returns nil for a repo with no .rubocop.yml" do
      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "lib/example.rb" ])).to be_nil
    end

    it "contributes the autocorrect command when .rubocop.yml is present" do
      FileUtils.touch(File.join(@dir, ".rubocop.yml"))

      expect(described_class.autofix_command(workspace_path: @dir, changed_files: [ "lib/example.rb", "README.md" ])).to eq(
        "bundle exec rubocop -a -- lib/example.rb"
      )
    end
  end

  describe Ruby::ReviewCriteriaProvider do
    around do |ex|
      Dir.mktmpdir("syrus-ruby-review-criteria-provider") { |dir| @dir = dir; ex.run }
    end

    it "returns [] for a repo with no Gemfile" do
      expect(described_class.criteria(@dir)).to eq([])
    end

    it "contributes the N+1 criterion when a Gemfile is present" do
      FileUtils.touch(File.join(@dir, "Gemfile"))

      expect(described_class.criteria(@dir)).to eq([ "Flag new N+1 query patterns in ActiveRecord code" ])
    end
  end
end
