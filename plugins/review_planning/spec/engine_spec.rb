require "rails_helper"

RSpec.describe ReviewPlanning::Engine do
  def manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "review_planning" }

  def parse(yaml) = SyrusYml.new(yaml).parse

  it "is a Rails::Engine that registers the retired step kind" do
    expect(described_class.superclass).to eq(Rails::Engine)
    entry = Step::Kind.fetch("review_plan")
    expect(entry.handler_class).to eq(ReviewPlanning::LegacyStep)
    expect(entry.agentic).to be(false)
    expect(entry.required_mcp_tools).to eq([])
    expect(entry.fail_policy).to eq(:advance)
  end

  it "is disableable" do
    expect(manifest.disableable).to be(true)
  end

  it "does not materialize the step for any repository, opted in or not" do
    expect(Workflows::CompositionAnchors.post_pr(job: Factories.job)).not_to include("review_plan")
  end

  it "parses the legacy review_plan key as an inert plugin configuration" do
    key = ReviewPlanning::RepositoryConfiguration::KEY

    expect(parse("review_plan: true\n").plugin_configurations[key]).to be(true)
    expect(parse("review_plan: \"yes\"\n").plugin_configurations[key]).to be(true)
    expect(parse("review_plan: false\n").plugin_configurations[key]).to be(false)
    expect(parse("prepare: []\n").plugin_configurations[key]).to be_nil
  end

  it "withholds the step kind and key when disabled" do
    PluginRecord.find_or_create_by!(name: "review_planning").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(Step::Kind.values).not_to include("review_plan")
    expect(parse("review_plan: true\n").plugin_configurations[ReviewPlanning::RepositoryConfiguration::KEY]).to be_nil
  ensure
    PluginRecord.find_by(name: "review_planning")&.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end
end
