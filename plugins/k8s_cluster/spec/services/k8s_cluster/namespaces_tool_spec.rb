require "rails_helper"

RSpec.describe K8sCluster::NamespacesTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, name: nil)
    described_class.call(server_context: {}, cluster_id: cluster_id, name: name)
  end

  it "lists namespaces when no name is given" do
    payload = { available: true, namespaces: [ { name: "default" } ] }
    service = instance_double(K8sCluster::Namespaces, list: payload)
    allow(K8sCluster::Namespaces).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(service).to have_received(:list)
    expect(JSON.parse(response.content.first[:text], symbolize_names: true)).to eq(payload)
  end

  it "describes a single namespace when name is given" do
    payload = { available: true, namespace: { "metadata" => { "name" => "default" } } }
    service = instance_double(K8sCluster::Namespaces, describe: payload)
    allow(K8sCluster::Namespaces).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, name: "default")

    expect(response.error?).to be(false)
    expect(service).to have_received(:describe).with("default")
  end

  it "returns an error response when the cluster cannot be reached" do
    service = instance_double(K8sCluster::Namespaces)
    allow(service).to receive(:list).and_raise(K8sCluster::ResourceService::Unavailable, "connection refused")
    allow(K8sCluster::Namespaces).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("connection refused")
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
