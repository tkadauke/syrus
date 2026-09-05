require "rails_helper"

RSpec.describe K8sCluster::ScaleDeploymentTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true, allow_writes: true) }

  def call(cluster_id:, namespace: "default", name: "web", replicas: 5)
    described_class.call(server_context: {}, cluster_id: cluster_id, namespace: namespace, name: name, replicas: replicas)
  end

  it "scales the deployment" do
    payload = { available: true, before: { replicas: 2 }, after: { replicas: 5 } }
    service = instance_double(K8sCluster::Deployments, scale: payload)
    allow(K8sCluster::Deployments).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id, replicas: 5)

    expect(response.error?).to be(false)
    expect(service).to have_received(:scale).with("web", namespace: "default", replicas: 5)
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

  it "rejects a negative replica count before touching the cluster" do
    # No WebMock stub is registered for this cluster's API server, so if the
    # validation guard inside Deployments#scale didn't short-circuit before
    # the network call, this would fail with a connection error instead.
    response = call(cluster_id: cluster.id, replicas: -1)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("non-negative")
  end
end
