require "rails_helper"

RSpec.describe K8sCluster::ServicesTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, namespace: nil, name: nil)
    described_class.call(server_context: {}, cluster_id: cluster_id, namespace: namespace, name: name)
  end

  it "lists services" do
    payload = { available: true, services: [] }
    service = instance_double(K8sCluster::Services, list: payload)
    allow(K8sCluster::Services).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, namespace: "default")

    expect(response.error?).to be(false)
    expect(service).to have_received(:list).with(namespace: "default")
  end

  it "describes a single service when name and namespace are given" do
    payload = { available: true, service: { "metadata" => { "name" => "web" } } }
    service = instance_double(K8sCluster::Services, describe: payload)
    allow(K8sCluster::Services).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, namespace: "default", name: "web")

    expect(response.error?).to be(false)
    expect(service).to have_received(:describe).with("web", namespace: "default")
  end

  it "refuses to describe without a namespace" do
    response = call(cluster_id: cluster.id, name: "web")

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("namespace is required")
  end

  it "refuses when the cluster has agentic access disabled" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = call(cluster_id: disabled.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
