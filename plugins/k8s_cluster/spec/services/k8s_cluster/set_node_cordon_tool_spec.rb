require "rails_helper"

RSpec.describe K8sCluster::SetNodeCordonTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true, allow_writes: true) }

  def call(cluster_id:, name: "node-1", cordoned: true)
    described_class.call(server_context: {}, cluster_id: cluster_id, name: name, cordoned: cordoned)
  end

  it "cordons the node" do
    payload = { available: true, before: { unschedulable: false }, after: { unschedulable: true } }
    service = instance_double(K8sCluster::Nodes, set_cordon: payload)
    allow(K8sCluster::Nodes).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, cordoned: true)

    expect(response.error?).to be(false)
    expect(service).to have_received(:set_cordon).with("node-1", cordoned: true)
  end

  it "uncordons the node" do
    payload = { available: true, before: { unschedulable: true }, after: { unschedulable: false } }
    service = instance_double(K8sCluster::Nodes, set_cordon: payload)
    allow(K8sCluster::Nodes).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, cordoned: false)

    expect(response.error?).to be(false)
    expect(service).to have_received(:set_cordon).with("node-1", cordoned: false)
  end

  it "refuses when the cluster does not exist" do
    response = call(cluster_id: -1)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("was not found")
  end

  it "refuses when the cluster has agentic access disabled" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false, allow_writes: true)

    response = call(cluster_id: disabled.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end

  it "refuses when writes are disabled even though agentic access is enabled" do
    read_only = Factories.kubernetes_cluster(agentic_access_enabled: true, allow_writes: false)

    response = call(cluster_id: read_only.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Write access is disabled")
  end
end
