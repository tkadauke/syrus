require "rails_helper"

RSpec.describe K8sCluster::SidebarPages do
  # The very first User created in an example is auto-promoted to admin
  # (User#promote_first_user_to_admin), regardless of an explicit
  # `admin: false`. Burn that slot up front so `member` below reliably stays
  # non-admin.
  let!(:seed_user) { Factories.user(admin: true) }
  let(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }

  def enable_plugin!
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
  end

  it "is empty when the plugin is disabled" do
    Current.api_user = admin

    expect(described_class.sidebar_pages).to eq([])
  end

  it "is empty for a non-admin even when the plugin is enabled" do
    enable_plugin!
    Current.api_user = member

    expect(described_class.sidebar_pages).to eq([])
  end

  it "is empty when there is no current user" do
    enable_plugin!

    expect(described_class.sidebar_pages).to eq([])
  end

  it "declares the K8s Clusters sidebar page for an admin once fully enabled" do
    enable_plugin!
    Current.api_user = admin

    expect(described_class.sidebar_pages).to contain_exactly(
      include(
        id: "k8s_cluster.clusters",
        label: "K8s Clusters",
        label_key: "k8s_cluster:nav_k8s_clusters",
        path: "/k8s_clusters",
        paths: [ "/k8s_clusters" ],
        component: "k8s_cluster/KubernetesClusters",
        icon: "server"
      )
    )
  end
end
