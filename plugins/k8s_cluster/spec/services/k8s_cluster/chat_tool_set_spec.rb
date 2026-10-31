require "rails_helper"

RSpec.describe K8sCluster::ChatToolSet do
  let(:chat_session) { ChatSession.create!(user: Factories.user(admin: true)) }

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

  it "is available without a saved cluster when credential-backed kubectl can run" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    allow(CredentialStore).to receive(:enabled?).and_return(true)

    expect(described_class.available_for?(chat_session, tier: :essential)).to be(true)
    expect(described_class.tool_definitions(tier: :essential).map { |tool| tool.fetch(:name) }).to include("k8s_cluster_kubectl")
  end

  it "is unavailable when no cluster has been configured and credential_store is disabled" do
    allow(K8sCluster).to receive(:enabled?).and_return(true)
    allow(CredentialStore).to receive(:enabled?).and_return(false)

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
      "k8s_cluster_statefulsets",
      "k8s_cluster_daemonsets",
      "k8s_cluster_jobs",
      "k8s_cluster_services",
      "k8s_cluster_ingresses",
      "k8s_cluster_configmaps",
      "k8s_cluster_secrets",
      "k8s_cluster_events",
      "k8s_cluster_pvcs",
      "k8s_cluster_cronjobs",
      "k8s_cluster_overview",
      "k8s_cluster_restart_rollout",
      "k8s_cluster_scale_deployment",
      "k8s_cluster_delete_pod",
      "k8s_cluster_set_node_cordon",
      "k8s_cluster_kubectl"
    )
    expect(tools.find { |tool| tool.fetch(:name) == "k8s_cluster_pods" }.fetch(:description)).to include("k8s_cluster_list_clusters")
    expect(tools.find { |tool| tool.fetch(:name) == "k8s_cluster_pod_logs" }.dig(:input_schema, :required)).to eq([ "cluster_id", "name", "namespace" ])
  end

  it "advertises only the read-only cluster tools through k8s.read" do
    coworker_tools = described_class.tool_definitions(tier: :essential).select { |tool| tool[:coworker_safe] }

    expect(coworker_tools.map { |tool| tool.fetch(:name) }).to contain_exactly(
      "k8s_cluster_list_clusters", "k8s_cluster_namespaces", "k8s_cluster_nodes", "k8s_cluster_pods",
      "k8s_cluster_pod_logs", "k8s_cluster_deployments", "k8s_cluster_statefulsets", "k8s_cluster_daemonsets",
      "k8s_cluster_jobs", "k8s_cluster_cronjobs", "k8s_cluster_services", "k8s_cluster_ingresses",
      "k8s_cluster_pvcs", "k8s_cluster_events", "k8s_cluster_configmaps", "k8s_cluster_overview"
    )
    expect(coworker_tools).to all(include(capability: "k8s.read"))
    expect(described_class.coworker_grants.first).to include(default_policy: "confirm", maximum_policy: "auto")
  end

  it "never advertises privileged Kubernetes tools to coworkers" do
    permanently_excluded = %w[
      k8s_cluster_secrets k8s_cluster_kubectl k8s_cluster_delete_pod
      k8s_cluster_restart_rollout k8s_cluster_scale_deployment k8s_cluster_set_node_cordon
    ]

    definitions = described_class.tool_definitions(tier: :essential).index_by { |tool| tool.fetch(:name) }
    registered_grant_tools = Syrus::PluginRegistry.providers_for(:chat_mcp_tool_set).flat_map do |provider|
      provider.respond_to?(:coworker_grants) ? provider.coworker_grants.flat_map { |grant| grant.fetch(:tools) } : []
    end
    permanently_excluded.each do |tool_name|
      expect(definitions.fetch(tool_name)).not_to include(:coworker_safe, :capability)
      expect(registered_grant_tools).not_to include(tool_name)
    end
  end

  it "advertises nothing to a coworker without k8s.read and only read tools with a scoped grant" do
    owner = Factories.user(admin: true)
    cluster = Factories.kubernetes_cluster(agentic_access_enabled: true)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Gilfoyle", handle: "gilfoyle-k8s",
      workspace_repo: "https://github.com/example/workspace.git")
    chat = ChatSession.create!(user: owner)
    chat.define_singleton_method(:coworker) { coworker }
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!

    expect(Mcp::Sidecar.mcp_tools_for(described_class, tier: :essential, chat_session: chat, policy: :coworker)).to be_empty

    coworker.grants.create!(capability: "k8s.read", approval_policy: "confirm", scope: cluster.id)
    names = Mcp::Sidecar.mcp_tools_for(described_class, tier: :essential, chat_session: chat, policy: :coworker)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }
    expect(names).to match_array(described_class::COWORKER_READ_TOOLS.map(&:tool_name))
  end

  it "dispatches to the matching tool class, passing string-keyed params through" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = described_class.new.handle("k8s_cluster_namespaces", { "cluster_id" => disabled.id }, { chat_session: chat_session })

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end

  it "reports unknown tool names without dispatching" do
    response = described_class.new.handle("nonexistent_tool", {}, {})

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Unknown K8s Cluster tool")
  end
end
