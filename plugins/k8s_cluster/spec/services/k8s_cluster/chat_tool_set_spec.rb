require "rails_helper"

RSpec.describe K8sCluster::ChatToolSet do
  let(:chat_session) { instance_double(ChatSession) }

  it "is unavailable when the plugin is disabled" do
    allow(K8sCluster).to receive(:enabled?).and_return(false)
    Factories.kubernetes_cluster(agentic_access_enabled: true)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(false)
  end

  it "is available when clusters exist so agents can inspect safe access metadata" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    Factories.kubernetes_cluster(agentic_access_enabled: false)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(true)
  end

  it "is unavailable when no cluster has been configured" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(false)
  end

  it "is available once at least one cluster exists" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    Factories.kubernetes_cluster(agentic_access_enabled: true)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(true)
    expect(described_class.available_for?(chat_session, tier: :deferred)).to be(true)
  end

  it "is unavailable for tiers outside essential/deferred" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    Factories.kubernetes_cluster(agentic_access_enabled: true)

    expect(described_class.available_for?(chat_session, tier: :evaluator)).to be(false)
  end

  it "exposes the cluster browse tools" do
    tools = described_class.tool_definitions(tier: :essential)

    expect(tools.map { |tool| tool.fetch(:name) }).to contain_exactly(
      "k8s_cluster_list_clusters",
      "k8s_cluster_namespaces",
      "k8s_cluster_nodes",
      "k8s_cluster_pods",
      "k8s_cluster_pod_logs",
      "k8s_cluster_deployments",
      "k8s_cluster_services",
      "k8s_cluster_events",
      "k8s_cluster_pvcs",
      "k8s_cluster_cronjobs",
      "k8s_cluster_overview"
    )
    expect(tools.find { |tool| tool.fetch(:name) == "k8s_cluster_pods" }.fetch(:description)).to include("k8s_cluster_list_clusters")
    expect(tools.find { |tool| tool.fetch(:name) == "k8s_cluster_pod_logs" }.dig(:input_schema, :required)).to eq([ "cluster_id", "name", "namespace" ])
  end

  it "dispatches to the matching tool class, passing string-keyed params through" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = described_class.new.handle("k8s_cluster_namespaces", { "cluster_id" => disabled.id }, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end

  it "reports unknown tool names without dispatching" do
    response = described_class.new.handle("nonexistent_tool", {}, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unknown K8s Cluster tool")
  end
end
