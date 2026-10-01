require "rails_helper"

RSpec.describe CognitiveReview::Engine do
  before do
    PluginRecord.find_or_create_by!(name: "cognitive_review").update!(enabled: true, default_enabled: false, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "is a Rails::Engine" do
    expect(described_class.superclass).to eq(Rails::Engine)
  end

  it "registers its workflow and review-tab providers" do
    expect(Syrus::PluginRegistry.providers_for(:post_implementation_review_provider)).to include(CognitiveReview::PostImplementationReviewProvider)
    expect(Syrus::PluginRegistry.providers_for(:diff_review_annotation_provider)).to include(CognitiveReview::DiffReviewAnnotationProvider)
    expect(Syrus::PluginRegistry.providers_for(:mcp_tool_set)).to include(CognitiveReview::McpToolSet)
  end

  it "withholds providers when disabled without deleting workflow artifacts" do
    job = Factories.job_with_run(step_attrs: { kind: "post_implementation_review" })
    job.latest_workflow.set_artifact!(CognitiveReview::Artifact::KEY, [ { "notes" => [] } ])

    PluginRecord.find_by!(name: "cognitive_review").update!(enabled: false)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(Syrus::PluginRegistry.providers_for(:post_implementation_review_provider)).not_to include(CognitiveReview::PostImplementationReviewProvider)
    expect(Syrus::PluginRegistry.providers_for(:diff_review_annotation_provider)).not_to include(CognitiveReview::DiffReviewAnnotationProvider)
    expect(Syrus::PluginRegistry.providers_for(:mcp_tool_set)).not_to include(CognitiveReview::McpToolSet)
    expect(job.latest_workflow.reload.artifact(CognitiveReview::Artifact::KEY)).to eq([ { "notes" => [] } ])
  end

  it "declares Agent Memory as optional rather than required" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "cognitive_review" }

    expect(manifest.default_enabled).to be(false)
    expect(manifest.disableable).to be(true)
    expect(manifest.optionally_depends_on).to include("agent_memory")
    expect(manifest.depends_on).to be_empty
  end

  it "includes the required provider interface modules" do
    expect(CognitiveReview::PostImplementationReviewProvider.ancestors).to include(Syrus::Plugin::PostImplementationReviewProvider)
    expect(CognitiveReview::DiffReviewAnnotationProvider.ancestors).to include(Syrus::Plugin::DiffReviewAnnotationProvider)
    expect(CognitiveReview::McpToolSet.ancestors).to include(Syrus::Plugin::McpToolSet)
  end
end
