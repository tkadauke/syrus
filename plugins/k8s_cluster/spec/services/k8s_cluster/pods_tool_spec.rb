require "rails_helper"

RSpec.describe K8sCluster::PodsTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, namespace: nil, name: nil)
    described_class.call(server_context: {}, cluster_id: cluster_id, namespace: namespace, name: name)
  end

  it "lists pods across all namespaces when neither name nor namespace is given" do
    payload = { available: true, pods: [ { name: "web-1", namespace: "default" } ] }
    service = instance_double(K8sCluster::Pods, list: payload)
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(service).to have_received(:list).with(namespace: nil)
  end

  it "scopes the list to one namespace" do
    payload = { available: true, pods: [] }
    service = instance_double(K8sCluster::Pods, list: payload)
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    call(cluster_id: cluster.id, namespace: "default")

    expect(service).to have_received(:list).with(namespace: "default")
  end

  it "describes a single pod when name and namespace are given" do
    payload = { available: true, pod: { "metadata" => { "name" => "web-1" } } }
    service = instance_double(K8sCluster::Pods, describe: payload)
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, namespace: "default", name: "web-1")

    expect(response.error?).to be(false)
    expect(service).to have_received(:describe).with("web-1", namespace: "default")
  end

  it "refuses to describe a pod without a namespace" do
    response = call(cluster_id: cluster.id, name: "web-1")

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
