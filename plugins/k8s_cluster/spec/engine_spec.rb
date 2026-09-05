require "rails_helper"

RSpec.describe K8sCluster::Engine do
  it "is registered disabled by default for the standard bundled-plugin test setup" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "k8s_cluster" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.enabled?).to be(false)
    expect(manifest.metadata[:frontend]).to eq(
      routes: { "k8s_cluster/KubernetesClusters" => "app/frontend/routes/KubernetesClusters.tsx" },
      i18n: [ "app/frontend/i18n/locales/*/k8s_cluster.json" ]
    )
  end

  it "registers the sidebar page provider even before the plugin is enabled" do
    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).not_to include(K8sCluster::SidebarPages)

    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)

    expect(Syrus::PluginRegistry.providers_for(:sidebar_page)).to include(K8sCluster::SidebarPages)
  end

  describe ".enabled?" do
    it "is false when the plugin record is not enabled" do
      expect(K8sCluster.enabled?).to be(false)
    end

    it "is true once the plugin record is enabled" do
      PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)

      expect(K8sCluster.enabled?).to be(true)
    end
  end
end
