require "rails_helper"

RSpec.describe K8sCluster::DeploymentsTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, namespace: nil, name: nil)
    described_class.call(server_context: {}, cluster_id: cluster_id, namespace: namespace, name: name)
  end

  it "lists deployments" do
    payload = { available: true, deployments: [] }
    service = instance_double(K8sCluster::Deployments, list: payload)
    allow(K8sCluster::Deployments).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, namespace: "default")

    expect(response.error?).to be(false)
    expect(service).to have_received(:list).with(namespace: "default")
  end

  it "describes a single deployment when name and namespace are given" do
    payload = { available: true, deployment: { "metadata" => { "name" => "web" } } }
    service = instance_double(K8sCluster::Deployments, describe: payload)
    allow(K8sCluster::Deployments).to receive(:new).with(cluster).and_return(service)

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
