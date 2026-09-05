require "rails_helper"

RSpec.describe K8sCluster::EventsTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, namespace: nil)
    described_class.call(server_context: {}, cluster_id: cluster_id, namespace: namespace)
  end

  it "lists events across all namespaces when none is given" do
    payload = { available: true, events: [] }
    service = instance_double(K8sCluster::Events, list: payload)
    allow(K8sCluster::Events).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(service).to have_received(:list).with(namespace: nil)
  end

  it "scopes the list to one namespace" do
    payload = { available: true, events: [] }
    service = instance_double(K8sCluster::Events, list: payload)
    allow(K8sCluster::Events).to receive(:new).with(cluster).and_return(service)

    call(cluster_id: cluster.id, namespace: "default")

    expect(service).to have_received(:list).with(namespace: "default")
  end

  it "refuses when the cluster has agentic access disabled" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = call(cluster_id: disabled.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end

  it "refuses for an unknown cluster id" do
    response = call(cluster_id: -1)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("was not found")
  end
end
