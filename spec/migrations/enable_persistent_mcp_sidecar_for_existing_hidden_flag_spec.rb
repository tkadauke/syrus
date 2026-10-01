require "rails_helper"
require Rails.root.join("db/migrate/20261001153849_enable_persistent_mcp_sidecar_for_existing_hidden_flag")

RSpec.describe EnablePersistentMcpSidecarForExistingHiddenFlag, :ci_only do
  let(:migration) { described_class.new }

  after do
    migration.up
    Feature.clear_enabled_cache!("persistent_mcp_sidecar")
  end

  it "enables an existing hidden persistent MCP feature row during upgrades" do
    feature = Feature.find_or_create_by!(slug: "persistent_mcp_sidecar") do |record|
      record.category = "Labs"
      record.name = "Persistent MCP sidecar"
    end
    feature.update!(enabled: false, default_enabled: false)

    migration.up

    expect(feature.reload).to have_attributes(enabled: true, default_enabled: true)
  end

  it "does not create the feature row when YAML sync has not seeded it yet" do
    Feature.where(slug: "persistent_mcp_sidecar").delete_all

    expect { migration.up }.not_to change(Feature, :count)
  end
end
