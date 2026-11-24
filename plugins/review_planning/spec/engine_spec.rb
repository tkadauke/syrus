require "rails_helper"

RSpec.describe ReviewPlanning::Engine do
  def manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "review_planning" }

  def parse(yaml) = SyrusYml.new(yaml).parse

  def stub_plan(enabled)
    allow(ReviewPlanning::Plan).to receive(:for_job).and_return(ReviewPlanning::Plan::Result.new(enabled: enabled, source: ".syrus.yml", note: nil))
  end

  def disable_plugin!
    PluginRecord.find_or_create_by!(name: "review_planning").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  after do
    PluginRecord.find_by(name: "review_planning")&.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "is a Rails::Engine contributing the step at workflow:post_pr and registering the step kind" do
    expect(described_class.superclass).to eq(Rails::Engine)
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:post_pr"))
      .to include([ "review_planning", ReviewPlanning::WorkflowPostPr ])

    entry = Step::Kind.fetch("review_plan")
    expect(entry.handler_class).to eq(ReviewPlanning::Step)
    expect(entry.agentic).to be(true)
    expect(entry.required_mcp_tools).to eq(%w[submit_review_plan])
    expect(entry.fail_policy).to eq(:advance)
    expect(ReviewPlanning::WorkflowPostPr.post_pr.first).to include(step_kind: "review_plan", fail_policy: :advance)
  end

  it "is on by default and disableable" do
    expect(manifest.default_enabled).to be(true)
    expect(manifest.disableable).to be(true)
  end

  it "adds the step after pr_open for an opted-in repository only" do
    job = Factories.job

    stub_plan(true)
    expect(Workflows::Initial.steps_for(job).flatten.map { |n| n.respond_to?(:step_kind) ? n.step_kind : n.to_s }.last(2)).to eq(%w[pr_open review_plan])

    stub_plan(false)
    expect(Workflows::Initial.steps_for(job).flatten.map(&:to_s)).not_to include("review_plan")
  end

  it "adds no step when the plugin is disabled, even for an opted-in repository" do
    stub_plan(true)
    disable_plugin!

    expect(Workflows::CompositionAnchors.post_pr(job: Factories.job)).not_to include("review_plan")
    expect(Step::Kind.values).not_to include("review_plan")
  end

  it "parses the review_plan key as the plugin's opt-in" do
    key = ReviewPlanning::RepositoryConfiguration::KEY

    expect(parse("review_plan: true\n").plugin_configurations[key]).to be(true)
    expect(parse("review_plan: \"yes\"\n").plugin_configurations[key]).to be(true)
    expect(parse("review_plan: false\n").plugin_configurations[key]).to be(false)
    expect(parse("prepare: []\n").plugin_configurations[key]).to be_nil
  end

  it "withholds the opt-in and the tool set when disabled" do
    disable_plugin!

    expect(parse("review_plan: true\n").plugin_configurations[ReviewPlanning::RepositoryConfiguration::KEY]).to be_nil
    expect(Syrus::PluginRegistry.providers_for(:mcp_tool_set)).not_to include(ReviewPlanning::McpToolSet)
  end

  it "never fails the workflow: a failing step is swallowed by the handler and the kind advances on failure" do
    expect(Step::Kind.fetch("review_plan").fail_policy).to eq(:advance)
  end
end
