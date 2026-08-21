require "rails_helper"

RSpec.describe GraderCommandSpans::Plan do
  # Per-language sub-command labels come from each enabled :prepare_detector
  # plugin's span_labels rather than a hardcoded core list. Register the real
  # bundled `ruby` and `javascript` plugins (mirroring their engine.rb
  # manifests) so these specs exercise the actual production wiring.
  before do |example|
    next if example.metadata[:reset_plugin_registry]

    unless Syrus::PluginRegistry.registered_names.include?("ruby")
      Syrus::PluginRegistry.register(
        name: "ruby", version: Ruby::VERSION, prepare_priority: 10,
        provides: { prepare_detector: Ruby::PrepareDetector }
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("javascript")
      Syrus::PluginRegistry.register(
        name: "javascript", version: JavaScript::VERSION, prepare_priority: 20,
        provides: { prepare_detector: JavaScript::PrepareDetector }
      )
    end
  end

  after { Syrus::PluginRegistry.reset! }

  it "splits common composite grader commands into readable phases" do
    plan = described_class.for("bundle check || bundle install && bin/rails db:test:prepare && bin/rspec")

    expect(plan).to be_instrumentable
    expect(plan.fragments.map(&:name)).to eq([ "bundle check", "bundle install", "db:test:prepare", "rspec" ])
    expect(plan.fragments.map(&:operator_before)).to eq([ nil, "||", "&&", "&&" ])
  end

  it "falls back to one span for commands without top-level phases" do
    plan = described_class.for("bin/rspec spec/models")

    expect(plan).not_to be_instrumentable
    expect(plan.fallback_reason).to eq("no top-level shell operators")
    expect(plan.fragments.first.name).to eq("rspec")
  end

  it "does not split operators inside quotes" do
    plan = described_class.for("ruby -e 'puts \"a && b\"' && npm run test:react")

    expect(plan.fragments.map(&:command)).to eq([ "ruby -e 'puts \"a && b\"'", "npm run test:react" ])
    expect(plan.fragments.map(&:name)).to eq([ "ruby -e 'puts #1", "frontend tests" ])
  end

  it "falls back for shell control flow instead of splitting internal semicolons" do
    plan = described_class.for("if bundle check; then bin/rspec; else bundle install && bin/rspec; fi")

    expect(plan).not_to be_instrumentable
    expect(plan.fallback_reason).to eq("contains shell control flow")
  end

  it "still labels core generic sub-commands that aren't tied to one language" do
    plan = described_class.for(
      "bin/check-migrations && bin/check-eager-load && bin/check-production-build-boot && npm run --prefix website build"
    )

    expect(plan.fragments.map(&:name)).to eq(
      [ "migration checks", "eager load check", "production build boot", "website build" ]
    )
  end

  it "labels rubocop and frontend build sub-commands from plugin span_labels" do
    plan = described_class.for("bin/rubocop && npm run build")

    expect(plan.fragments.map(&:name)).to eq([ "rubocop", "frontend build" ])
  end

  describe "with no :prepare_detector plugins registered", :reset_plugin_registry do
    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    it "falls back to the generic first-3-words label instead of raising" do
      plan = described_class.for("bin/rspec spec/models && bin/rubocop")

      expect(plan.fragments.map(&:name)).to eq([ "bin/rspec spec/models #1", "bin/rubocop #2" ])
    end
  end

  describe "with a plugin-contributed span label", :reset_plugin_registry do
    around do |ex|
      Syrus::PluginRegistry.reset!
      ex.run
      Syrus::PluginRegistry.reset!
    end

    it "uses a registered plugin's span_labels before falling back" do
      detector = Class.new { include Syrus::Plugin::PrepareDetector }
      detector.define_singleton_method(:detect?) { |_repo_path| true }
      detector.define_singleton_method(:prepare_commands) { |_repo_path| [] }
      detector.define_singleton_method(:span_labels) { [ [ /\bmy_custom_tool\b/, "custom tool" ] ] }

      Syrus::PluginRegistry.register(
        name: "my_custom_plugin", version: "1.0.0",
        provides: { prepare_detector: detector }
      )

      plan = described_class.for("my_custom_tool run && bin/some_other_unlabeled_tool")

      expect(plan.fragments.map(&:name)).to eq([ "custom tool", "bin/some_other_unlabeled_tool #2" ])
    end
  end
end
