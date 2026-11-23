require "rails_helper"
require_relative "support/snapshot_factory"

RSpec.describe SyrusCoverage::Engine do
  def manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "syrus_coverage" }

  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "contributes at the post_implementation and post_pr anchors and registers its step kinds" do
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:post_implementation"))
      .to include([ "syrus_coverage", SyrusCoverage::WorkflowPostImplementation ])
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:post_pr"))
      .to include([ "syrus_coverage", SyrusCoverage::WorkflowPostPr ])
    expect(Step::Kind.fetch("coverage_analyze").handler_class).to eq(SyrusCoverage::AnalyzeStep)
    expect(Step::Kind.fetch("coverage_pr_comment").handler_class).to eq(SyrusCoverage::PrCommentStep)
  end

  it "does not contribute a judge, so it can never run inside a review loop" do
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:judge").map(&:first)).not_to include("syrus_coverage")
  end

  it "owns the .syrus.yml coverage block, its tool, its data hooks and its skill" do
    expect(Syrus::PluginRegistry.providers_for(:repository_configuration)).to include(SyrusCoverage::RepositoryConfiguration)
    expect(Syrus::PluginRegistry.providers_for(:mcp_tool_set)).to include(SyrusCoverage::McpToolSet)
    expect(Syrus::PluginRegistry.providers_for(:permission_provider)).to include(SyrusCoverage::PermissionProvider)
    expect(Syrus::PluginRegistry.providers_for(:domain_subscriber)).to include(SyrusCoverage::Subscribers)
    expect(Syrus::PluginRegistry.providers_for(:line_coverage_provider)).to include(SyrusCoverage::LineCoverageProvider)
    expect(Syrus::PluginRegistry.providers_for(:skill)).to include(SyrusCoverage::SkillProvider)
  end

  it "is on by default and disableable" do
    expect(manifest.default_enabled).to be(true)
    expect(manifest.disableable).to be(true)
  end

  it "withholds every provider when disabled while leaving recorded snapshots in place" do
    snapshot = SyrusCoverageFactories.snapshot

    PluginRecord.find_or_create_by!(name: "syrus_coverage").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(Syrus::PluginRegistry.providers_for(:mcp_tool_set)).not_to include(SyrusCoverage::McpToolSet)
    expect(Syrus::PluginRegistry.providers_with_owner_for("workflow:post_implementation").map(&:first)).not_to include("syrus_coverage")
    expect(Syrus::PluginRegistry.providers_for(:line_coverage_provider)).not_to include(SyrusCoverage::LineCoverageProvider)
    expect(SyrusCoverage::Snapshot.find_by(id: snapshot.id)).to be_present
  ensure
    PluginRecord.find_by(name: "syrus_coverage")&.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "uses the same root project id as the target graph" do
    expect(SyrusCoverage.root_project_id).to eq(TargetGraph::ROOT_PROJECT_ID)
  end
end
