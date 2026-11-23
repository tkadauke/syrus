require "rails_helper"

RSpec.describe GraderCommandSpans::Plan, requires_plugin: %w[ruby javascript] do
  # Sub-command labels for Ruby/JS-specific commands (rspec, bundle, frontend
  # tests, etc.) now come from the real `ruby`/`javascript` prepare_detector
  # plugins' `span_labels` instead of a hardcoded table here — mirroring the
  # bundled plugins these examples register (see repo_prep_plan_spec.rb).
  before do
    unless Syrus::PluginRegistry.registered_names.include?("ruby")
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "ruby", version: Syrus::PluginApi.default_version, prepare_priority: 10,
        family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
          family: :ecosystem, provider: "Ruby::Ecosystem", implements: %i[detect_prepare]
        ) ]
      )
    end

    unless Syrus::PluginRegistry.registered_names.include?("javascript")
      Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil,
        name: "javascript", version: Syrus::PluginApi.default_version, prepare_priority: 20,
        family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
          family: :ecosystem, provider: "JavaScript::Ecosystem", implements: %i[detect_prepare]
        ) ]
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

  it "still labels a core, language-agnostic sub-command" do
    plan = described_class.for("bin/check-migrations && bin/check-eager-load")

    expect(plan.fragments.map(&:name)).to eq([ "migration checks", "eager load check" ])
  end

  describe "plugin-contributed span_labels" do
    def register_detector(plugin_name:, span_labels:, prepare_priority: 100)
      detector = Class.new do
        define_singleton_method(:key) { plugin_name.to_sym }
        define_singleton_method(:display_name) { plugin_name }
      end
      detector.define_singleton_method(:detect_prepare) do |_context|
        [ Syrus::Host::EcosystemPreparePlan.new(detected: false, commands: [], version_file: nil,
          span_labels:, label: plugin_name) ]
      end
      register_ecosystem_provider(name: plugin_name, provider: detector, implements: %i[detect_prepare],
        prepare_priority:)
    end

    it "uses a plugin's span_labels to name a sub-command" do
      register_detector(plugin_name: "fake-lang", span_labels: [ [ /\bfoo-tool\b/, "foo tool" ] ])

      plan = described_class.for("foo-tool check && bin/check-eager-load")

      expect(plan.fragments.map(&:name)).to eq([ "foo tool", "eager load check" ])
    end
  end

  describe "with no plugins registered" do
    before { Syrus::PluginRegistry.reset! }

    it "still labels core, language-agnostic sub-commands" do
      plan = described_class.for("bin/rspec spec/models && bin/check-eager-load")

      expect(plan.fragments.map(&:name)).to eq([ "bin/rspec spec/models #1", "eager load check" ])
    end
  end
end
