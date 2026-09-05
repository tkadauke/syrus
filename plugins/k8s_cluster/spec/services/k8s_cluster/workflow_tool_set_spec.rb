require "rails_helper"

RSpec.describe K8sCluster::WorkflowToolSet do
  let(:repository) { instance_double(Repository) }
  let(:context) { instance_double(McpToolContext, role: AgentRole::WORKFLOW_IMPLEMENT, repository: repository) }

  it "is unavailable when the plugin is disabled" do
    allow(K8sCluster).to receive(:enabled?).and_return(false)
    Factories.kubernetes_cluster(agentic_access_enabled: true)

    expect(described_class.available_for?(repository)).to be(false)
    expect(described_class.available_for_context?(context)).to be(false)
  end

  it "is available when clusters exist so agents can inspect safe access metadata" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    Factories.kubernetes_cluster(agentic_access_enabled: false)

    expect(described_class.available_for_context?(context)).to be(true)
  end

  it "is unavailable when no cluster has been configured" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)

    expect(described_class.available_for_context?(context)).to be(false)
  end

  it "is available to implement agents once at least one cluster exists" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    Factories.kubernetes_cluster(agentic_access_enabled: true)

    expect(described_class.available_for_context?(context)).to be(true)
    expect(described_class.tool_definitions(context: context).map { |tool| tool.fetch(:name) }).to contain_exactly(
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
      "k8s_cluster_overview",
      "k8s_cluster_restart_rollout",
      "k8s_cluster_scale_deployment",
      "k8s_cluster_delete_pod",
      "k8s_cluster_set_node_cordon"
    )
  end

  it "does not expose tools to non-implement workflow roles" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    Factories.kubernetes_cluster(agentic_access_enabled: true)
    review_context = instance_double(McpToolContext, role: AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER, repository: repository)

    expect(described_class.available_for_context?(review_context)).to be(false)
    expect(described_class.tool_definitions(context: review_context)).to eq([])
  end

  it "delegates handling to ChatToolSet" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = described_class.new.handle("k8s_cluster_namespaces", { "cluster_id" => disabled.id }, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
