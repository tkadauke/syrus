require "rails_helper"

RSpec.describe "Standalone plugin points" do
  STANDALONE_POINTS = %i[
    preview_provider memory_store platform_delivery repository_recommendation
    workflow_artifact_contributor grader_failure_summarizer grader_input_materializer
    test_evidence approval_provider
  ].freeze

  let(:playbook) { File.read("docs/engineering/conventions/plugins/family-migration.md") }
  let(:decided) { playbook[/## Standalone points: decided(.*?)## Extension-point target inventory/m, 1] }

  it "keeps every decided point a registry point with an interface and description" do
    STANDALONE_POINTS.each do |point|
      expect(Syrus::PluginRegistry::EXTENSION_POINTS).to include(point)
      expect(Syrus::PluginRegistry::INTERFACE_FOR).to have_key(point)
      expect(Syrus::PluginRegistry::EXTENSION_POINT_DESCRIPTIONS).to have_key(point)
    end
  end

  it "keeps them out of every capability family" do
    claimed = Syrus::Plugin::Family.all.flat_map { |family| family.legacy_mappings.keys }
    expect(claimed & STANDALONE_POINTS).to be_empty
  end

  it "records a written reason for each point in the playbook" do
    expect(decided).to be_present
    STANDALONE_POINTS.each { |point| expect(decided).to include("`#{point}`") }
  end
end
