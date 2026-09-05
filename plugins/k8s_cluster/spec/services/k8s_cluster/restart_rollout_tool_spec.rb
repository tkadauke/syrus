require "rails_helper"

RSpec.describe K8sCluster::RestartRolloutTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true, allow_writes: true) }

  def call(cluster_id:, namespace: "default", name: "web")
    described_class.call(server_context: {}, cluster_id: cluster_id, namespace: namespace, name: name)
  end

  it "restarts the deployment's rollout" do
    payload = { available: true, before: { restarted_at: nil }, after: { restarted_at: "2026-09-05T00:00:00Z" } }
    service = instance_double(K8sCluster::Deployments, restart_rollout: payload)
    allow(K8sCluster::Deployments).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(service).to have_received(:restart_rollout).with("web", namespace: "default")
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
