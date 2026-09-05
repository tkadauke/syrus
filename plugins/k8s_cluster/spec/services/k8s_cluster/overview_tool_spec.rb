require "rails_helper"

RSpec.describe K8sCluster::OverviewTool do
  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:)
    described_class.call(server_context: {}, cluster_id: cluster_id)
  end

  it "returns the metrics overview" do
    payload = { generated_at: Time.current.iso8601, nodes: { available: true }, pods: { available: true } }
    overview = instance_double(K8sCluster::Overview, call: payload)
    allow(K8sCluster::Overview).to receive(:new).with(cluster).and_return(overview)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(overview).to have_received(:call)
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
