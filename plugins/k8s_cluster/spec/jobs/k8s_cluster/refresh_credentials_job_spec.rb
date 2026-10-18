require "rails_helper"

RSpec.describe K8sCluster::RefreshCredentialsJob do
  it "runs on a consumed maintenance queue" do
    expect(described_class.new.queue_name).to eq("low_priority_maintenance")
  end

  it "checks every cluster while the plugin is enabled" do
    first = Factories.kubernetes_cluster
    second = Factories.kubernetes_cluster
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    allow(K8sCluster::CredentialRefresher).to receive(:call)

    described_class.perform_now

    expect(K8sCluster::CredentialRefresher).to have_received(:call).with(first)
    expect(K8sCluster::CredentialRefresher).to have_received(:call).with(second)
  end
end
