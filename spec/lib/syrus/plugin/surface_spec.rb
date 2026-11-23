# frozen_string_literal: true

require "rails_helper"

RSpec.describe Syrus::Plugin::Surface, :reset_plugin_registry do
  let(:context) { Syrus::Plugin::Context::SurfaceContext.new }

  before { described_class.restore_definition! }

  it "defines the surface contracts and legacy mappings" do
    definition = Syrus::Plugin::Family.fetch(:surface)
    expect(definition.capabilities.keys).to eq(%i[
      sidebar_pages admin_pages repo_page_tabs workspace_tabs ui_slots artifact_renderers
      preview_panel_viewers filter_subjects filter_chips
    ])
    expect(definition.legacy_mappings.keys).to eq(%i[
      sidebar_page admin_page repo_page_tab workspace_tab ui_slot artifact_renderer preview_panel_viewer
    ])
  end

  it "adapts legacy-only registrations into family dispatch" do
    pages = Class.new { include Syrus::Plugin::SidebarPage }
    Syrus::PluginRegistry.register(default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "legacy_surface", version: "1", provides: { sidebar_page: pages })

    expect(described_class.contributions(:sidebar_pages)).to include(pages)
  end

  it "exposes family-only registrations through the legacy bridge" do
    stub_const("SurfaceFamilyPages", Class.new { def self.sidebar_pages = [] })
    stub_const("SurfaceFamilyProvider", described_class.provider(
      key: "family", display_name: "Family", sidebar_pages: "SurfaceFamilyPages"
    ))
    Syrus::PluginRegistry.register(
      default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "family_surface", version: "1", provides: {},
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family: :surface, provider: "SurfaceFamilyProvider", implements: %i[sidebar_pages]
      ) ]
    )

    bridged = Syrus::PluginRegistry.providers_for(:sidebar_page).find do |candidate|
      candidate.is_a?(Syrus::Plugin::LegacyBridge::Provider) && candidate.sidebar_pages == []
    end
    expect(bridged).not_to be_nil
  end

  it "reports doubled legacy and family registrations" do
    stub_const("DoubledSurfacePages", Class.new { include Syrus::Plugin::SidebarPage })
    stub_const("DoubledSurfaceProvider", described_class.provider(
      key: "doubled", display_name: "Doubled", sidebar_pages: "DoubledSurfacePages"
    ))
    Syrus::PluginRegistry.register(
      default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "doubled_surface", version: "1", provides: { sidebar_page: DoubledSurfacePages },
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family: :surface, provider: "DoubledSurfaceProvider", implements: %i[sidebar_pages]
      ) ]
    )

    expect(Syrus::PluginRegistry.legacy_bridge_duplicate_registrations.map(&:extension_point)).to include(:sidebar_page)
  end

  it "withholds a missing capability while loading the provider's remaining surfaces" do
    provider = Class.new do
      def self.key = "partial"
      def self.display_name = "Partial"
      def self.sidebar_pages(_context) = Class.new
    end
    stub_const("PartialSurfaceProvider", provider)
    Syrus::PluginRegistry.register(
      default_enabled: true, disableable: true, experimental: false, requires_syrus: nil, name: "partial_surface", version: "1", provides: {},
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family: :surface, provider: "PartialSurfaceProvider", implements: %i[sidebar_pages admin_pages]
      ) ]
    )

    expect(described_class.contributions(:sidebar_pages)).to include(a_kind_of(Class))
    expect(described_class.contributions(:admin_pages)).not_to include(provider)
    expect(Syrus::PluginRegistry.health.status("partial_surface").reasons.join).to include("admin_pages")
  end
end
