require "rails_helper"
require "tmpdir"

RSpec.describe Ruby::Engine do
  describe "PluginRegistry registration" do
    subject(:registration) do
      Syrus::PluginRegistry.all_plugins.find { |r| r.name == "ruby" }
    end

    before do
      # The after_initialize block runs once at boot; plugin_registry.rb resets
      # the in-memory registry in test mode. Re-register here so examples see
      # the manifest. Interface modules were included during after_initialize
      # and are permanent on the classes.
      unless Syrus::PluginRegistry.registered_names.include?("ruby")
        Syrus::PluginRegistry.register(
          name:             "ruby",
          version:          Ruby::VERSION,
          description:      "Ruby-generic intelligence: RSpec grader detail, RuboCop grader detail, " \
                             "RSpec output parsing, SimpleCov analysis, Gemfile prepare detection, " \
                             "default N+1 review criterion",
          homepage:         "https://github.com/tkadauke/syrus",
          prepare_priority: 10,
          provides: {
            coverage_analyzer:        Ruby::SimpleCovAnalyzer,
            grader_augmentor:         [ Ruby::GraderAugmentor, Ruby::RubocopGraderAugmentor ],
            prepare_detector:         Ruby::PrepareDetector,
            review_criteria_provider: Ruby::ReviewCriteriaProvider,
            test_result_parser:       Ruby::RspecParser
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
      expect(registration.version).to eq(Ruby::VERSION)
      expect(registration.prepare_priority).to eq(10)
    end

    it "provides all 5 extension point keys" do
      expect(registration.provides.keys).to contain_exactly(
        :coverage_analyzer,
        :grader_augmentor,
        :prepare_detector,
        :review_criteria_provider,
        :test_result_parser
      )
    end

    it "registers SimpleCovAnalyzer as the :coverage_analyzer" do
      expect(registration.provides[:coverage_analyzer]).to eq(Ruby::SimpleCovAnalyzer)
    end

    it "registers GraderAugmentor and RubocopGraderAugmentor as the :grader_augmentor providers" do
      expect(registration.provides[:grader_augmentor]).to eq(
        [ Ruby::GraderAugmentor, Ruby::RubocopGraderAugmentor ]
      )
    end

    it "registers PrepareDetector as the :prepare_detector" do
      expect(registration.provides[:prepare_detector]).to eq(Ruby::PrepareDetector)
    end

    it "registers ReviewCriteriaProvider as the :review_criteria_provider" do
      expect(registration.provides[:review_criteria_provider]).to eq(Ruby::ReviewCriteriaProvider)
    end

    it "registers RspecParser as the :test_result_parser" do
      expect(registration.provides[:test_result_parser]).to eq(Ruby::RspecParser)
    end

    it "surfaces both grader augmentors through providers_for" do
      expect(Syrus::PluginRegistry.providers_for(:grader_augmentor)).to include(
        Ruby::GraderAugmentor, Ruby::RubocopGraderAugmentor
      )
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
