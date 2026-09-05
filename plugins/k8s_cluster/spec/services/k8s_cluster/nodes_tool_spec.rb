require "rails_helper"

RSpec.describe K8sCluster::NodesTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, name: nil)
    described_class.call(server_context: {}, cluster_id: cluster_id, name: name)
  end

  it "lists nodes when no name is given" do
    payload = { available: true, nodes: [ { name: "node-1" } ] }
    service = instance_double(K8sCluster::Nodes, list: payload)
    allow(K8sCluster::Nodes).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(service).to have_received(:list)
  end

  it "describes a single node when name is given" do
    payload = { available: true, node: { "metadata" => { "name" => "node-1" } } }
    service = instance_double(K8sCluster::Nodes, describe: payload)
    allow(K8sCluster::Nodes).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, name: "node-1")

    expect(response.error?).to be(false)
    expect(service).to have_received(:describe).with("node-1")
  end

  it "refuses when the cluster has agentic access disabled" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = call(cluster_id: disabled.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
