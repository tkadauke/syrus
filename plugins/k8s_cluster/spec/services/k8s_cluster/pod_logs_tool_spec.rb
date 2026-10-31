require "rails_helper"

RSpec.describe K8sCluster::PodLogsTool do
  let(:chat_session) { ChatSession.create!(user: Factories.user(admin: true)) }

  let(:cluster) { Factories.kubernetes_cluster(agentic_access_enabled: true) }

  def call(cluster_id:, name: "web-1", namespace: "default", container: nil, tail_lines: nil, previous: false, timestamps: false)
    described_class.call(
      server_context: { chat_session: chat_session },
      cluster_id: cluster_id,
      name: name,
      namespace: namespace,
      container: container,
      tail_lines: tail_lines,
      previous: previous,
      timestamps: timestamps
    )
  end

  it "fetches the pod's log tail with the default tail_lines" do
    payload = { available: true, log: "line one\n" }
    service = instance_double(K8sCluster::Pods, logs: payload)
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(false)
    expect(service).to have_received(:logs).with("web-1", namespace: "default", container: nil, tail_lines: 200, previous: false, timestamps: false)
  end

  it "passes through container, tail_lines, previous, and timestamps" do
    payload = { available: true, log: "sidecar logs\n" }
    service = instance_double(K8sCluster::Pods, logs: payload)
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    call(cluster_id: cluster.id, container: "sidecar", tail_lines: 50, previous: true, timestamps: true)

    expect(service).to have_received(:logs).with("web-1", namespace: "default", container: "sidecar", tail_lines: 50, previous: true, timestamps: true)
  end

  it "redacts coworker pod logs and audits the coworker identity" do
    owner = Factories.user(admin: true)
    kubeconfig = K8sCluster::ClusterCredential.build_kubeconfig(
      api_server_url: cluster.api_server_url,
      credentials: { "token" => "broker-only-token" }
    )
    K8sCluster::ClusterCredential.upsert!(cluster: cluster, kubeconfig: kubeconfig, user: owner)
    cluster.save!
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Gilfoyle", handle: "gilfoyle-logs",
      workspace_repo: "https://github.com/example/workspace.git")
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    coworker.grants.create!(capability: "k8s.read", approval_policy: "confirm", scope: cluster.id)
    coworker_chat = ChatSession.create!(user: owner)
    coworker_chat.define_singleton_method(:coworker) { coworker }
    service = instance_double(K8sCluster::Pods, logs: { available: true, log: "API_TOKEN=very-secret-token-value" })
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)
    allow(K8sCluster::AgenticAudit).to receive(:log!)

    response = described_class.call(server_context: { chat_session: coworker_chat }, cluster_id: cluster.id,
      name: "web-1", namespace: "default")

    expect(response.content.first[:text]).to include(ToolPayloadRedactor::REDACTED)
    expect(response.content.first[:text]).not_to include("very-secret-token-value")
    expect(K8sCluster::AgenticAudit).to have_received(:log!).with(hash_including(context: have_attributes(agent_actor: coworker)))
  end

  it "audits the coworker identity when a cluster is outside the grant scope" do
    owner = Factories.user(admin: true)
    granted_cluster = Factories.kubernetes_cluster(agentic_access_enabled: true)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Gilfoyle", handle: "gilfoyle-log-errors",
      workspace_repo: "https://github.com/example/workspace.git")
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    coworker.grants.create!(capability: "k8s.read", approval_policy: "confirm", scope: granted_cluster.id)
    coworker_chat = ChatSession.create!(user: owner)
    coworker_chat.define_singleton_method(:coworker) { coworker }
    allow(K8sCluster::AgenticAudit).to receive(:log!)

    response = described_class.call(server_context: { chat_session: coworker_chat }, cluster_id: cluster.id,
      name: "web-1", namespace: "default")

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("outside the coworker grant scope")
    expect(K8sCluster::AgenticAudit).to have_received(:log!).with(hash_including(
      cluster_id: cluster.id,
      context: have_attributes(agent_actor: coworker),
      error: an_instance_of(K8sCluster::AgenticAccess::ClusterNotFound)
    ))
  end

  it "publishes the maximum supported log tail" do
    tail_lines = described_class.input_schema_value.to_h.dig(:properties, :tail_lines)

    expect(tail_lines[:maximum]).to eq(K8sCluster::Pods::MAX_LOG_TAIL_LINES)
  end

  it "returns an error response when the pod cannot be reached" do
    service = instance_double(K8sCluster::Pods)
    allow(service).to receive(:logs).and_raise(K8sCluster::ResourceService::Unavailable, "502")
    allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(service)

    response = call(cluster_id: cluster.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("502")
  end

  it "refuses when the cluster has agentic access disabled" do
    disabled = Factories.kubernetes_cluster(agentic_access_enabled: false)

    response = call(cluster_id: disabled.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
