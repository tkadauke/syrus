require "rails_helper"

RSpec.describe WorkerTimeline::Engine do
  it "is registered disabled by default for the standard bundled-plugin test setup" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "worker_timeline" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.enabled?).to be(false)
    expect(manifest.metadata[:frontend]).to eq(
      routes: { "worker_timeline/WorkerTimeline" => "app/frontend/routes/WorkerTimeline.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/worker_timeline.json" ]
    )
  end

  it "registers the Worker Timeline sidebar page provider even before the plugin is enabled" do
    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).not_to include(WorkerTimeline::SidebarPages)

    PluginRecord.find_by!(name: "worker_timeline").update!(enabled: true)

    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).to include(WorkerTimeline::SidebarPages)
  end

  describe ".enabled?" do
    it "is false when the plugin record is not enabled" do
      expect(WorkerTimeline.enabled?).to be(false)
    end

    it "is true once the plugin record is enabled" do
      PluginRecord.find_by!(name: "worker_timeline").update!(enabled: true)

      expect(WorkerTimeline.enabled?).to be(true)
    end
  end
end
