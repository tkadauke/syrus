require "rails_helper"

RSpec.describe MetricsDashboard::PluginTabs do
  # "metrics_dashboard:tab" only resolves while its host -- this plugin,
  # off by default -- is itself enabled (see Syrus::PluginRegistry
  # #hosted_providers_for). The contributor-side enablement tests below are
  # about a *contributor's* PluginRecord, not this one.
  before { PluginRecord.find_or_create_by!(name: "metrics_dashboard").update!(enabled: true, disableable: true) }

  # A fake, non-existent plugin name throughout -- metrics_dashboard never
  # names the plugins that actually contribute (spending_insights,
  # throughput, ...), the same "core specs must not enumerate
  # plugin-provided things" rule CLAUDE.md applies between sibling plugins,
  # not just plugin vs. core. See App::UiSlotsPayload's spec for the same
  # pattern applied to :ui_slot.
  #
  # Real bundled plugins (spending_insights, throughput, scheduled_tasks)
  # already contribute their own tabs unconditionally once this plugin is
  # enabled, so `described_class.build` is never empty by default here --
  # examples below assert against the fake contribution specifically
  # (mirroring sidecar_registry_tool_names's subtract-don't-assume-empty
  # approach in spec/services/mcp_tool_registry_spec.rb), never a bare `[]`.
  def provider(tabs)
    Class.new do
      class_attribute :tabs_to_return, :calls
      self.tabs_to_return = tabs
      self.calls = 0

      def self.metrics_dashboard_tabs
        self.calls += 1
        tabs_to_return
      end
    end
  end

  def register(provider_class, name: "widget_metrics")
    Syrus::PluginRegistry.register(name: name, version: "1.0.0", provides: { "metrics_dashboard:tab" => provider_class })
  end

  it "does not contribute a tab for a plugin that never registered one" do
    expect(described_class.build.map { |tab| tab[:id] }).not_to include("widgets")
  end

  it "normalizes a contributed tab's id, label, and panels" do
    register(provider([
      { id: "widgets", label: "Widgets", panels: [
        { key: "widgets_total", metric: "syrus_widget_metrics_widgets_total", group_by: "kind", mode: :rate, unit: "widgets", label: "Widgets, by kind" }
      ] }
    ]))

    expect(described_class.build.find { |tab| tab[:id] == "widgets" }).to eq(
      { id: "widgets", label: "Widgets", panels: [
        { key: "widgets_total", metric: "syrus_widget_metrics_widgets_total", group_by: "kind", mode: :rate, unit: "widgets", label: "Widgets, by kind" }
      ] }
    )
  end

  it "sorts tabs by label, alongside whatever else already contributed" do
    register(provider([ { id: "b_widgets", label: "B Widgets", panels: [] } ]), name: "b_widget_metrics")
    register(provider([ { id: "a_widgets", label: "A Widgets", panels: [] } ]), name: "a_widget_metrics")

    ids = described_class.build.map { |tab| tab[:id] }

    expect(ids.index("a_widgets")).to be < ids.index("b_widgets")
  end

  it "omits a tab from a disabled plugin" do
    klass = provider([ { id: "widgets", label: "Widgets", panels: [] } ])
    register(klass)
    PluginRecord.find_or_create_by!(name: "widget_metrics").update!(enabled: false, disableable: true)

    expect(described_class.build.map { |tab| tab[:id] }).not_to include("widgets")
  end

  it "supports a provider that contributes no tab" do
    register(provider([]))

    expect(described_class.build.map { |tab| tab[:id] }).not_to include("widgets")
  end

  it "returns nothing at all once metrics_dashboard itself is disabled, regardless of contributor state" do
    register(provider([ { id: "widgets", label: "Widgets", panels: [] } ]))
    PluginRecord.find_by!(name: "metrics_dashboard").update!(enabled: false)

    expect(described_class.build).to eq([])
  end
end
