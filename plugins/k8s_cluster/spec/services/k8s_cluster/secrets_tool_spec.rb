require "rails_helper"

RSpec.describe K8sCluster::SecretsTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, namespace: nil, name: nil)
    described_class.call(server_context: {}, cluster_id: cluster_id, namespace: namespace, name: name)
  end

  it "lists secrets without ever exposing data values" do
    payload = {
      available: true,
      secrets: [ { name: "db-credentials", namespace: "default", type: "Opaque", key_count: 1, key_names: [ "password" ] } ]
    }
    service = instance_double(K8sCluster::Secrets, list: payload)
    allow(K8sCluster::Secrets).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, namespace: "default")

    expect(response.error?).to be(false)
    expect(service).to have_received(:list).with(namespace: "default")
    expect(response.content.first[:text]).not_to include("c3VwZXItc2VjcmV0")
  end

  it "describes a single secret when name and namespace are given" do
    payload = { available: true, secret: { name: "db-credentials", namespace: "default", type: "Opaque", key_names: [ "password" ] } }
    service = instance_double(K8sCluster::Secrets, describe: payload)
    allow(K8sCluster::Secrets).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, namespace: "default", name: "db-credentials")

    expect(response.error?).to be(false)
    expect(service).to have_received(:describe).with("db-credentials", namespace: "default")
  end

  it "refuses to describe without a namespace" do
    response = call(cluster_id: cluster.id, name: "db-credentials")

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
