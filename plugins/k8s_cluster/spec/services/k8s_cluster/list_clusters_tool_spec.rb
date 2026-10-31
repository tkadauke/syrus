require "rails_helper"

RSpec.describe K8sCluster::ListClustersTool do
  let(:chat_session) { ChatSession.create!(user: Factories.user(admin: true)) }

  it "returns only safe cluster metadata, including agentic and write flags" do
    enabled = Factories.kubernetes_cluster(
      label: "Production",
      api_server_url: "https://prod-k8s.internal:6443",
      token: "prod-secret",
      agentic_access_enabled: true,
      allow_writes: false
    )
    disabled = Factories.kubernetes_cluster(
      label: "Staging",
      api_server_url: "https://staging-k8s.internal:6443",
      token: "staging-secret",
      agentic_access_enabled: false,
      allow_writes: true
    )

    response = described_class.call(server_context: { chat_session: chat_session })

    expect(response.error?).to be(false)
    payload = JSON.parse(response.content.first[:text])
    expect(payload.fetch("clusters")).to contain_exactly(
      {
        "id" => enabled.id,
        "label" => "Production",
        "agentic_access_enabled" => true,
        "allow_writes" => false,
        "created_at" => enabled.created_at.iso8601,
        "updated_at" => enabled.updated_at.iso8601
      }
    )

    serialized = response.content.first[:text]
    expect(serialized).not_to include("prod-secret")
    expect(serialized).not_to include("staging-secret")
    expect(serialized).not_to include("prod-k8s.internal")
  end

  it "audits the coworker identity and grant scope when listing fails" do
    owner = Factories.user(admin: true)
    cluster = Factories.kubernetes_cluster(agentic_access_enabled: true)
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Gilfoyle", handle: "gilfoyle-list-errors",
      workspace_repo: "https://github.com/example/workspace.git")
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    coworker.grants.create!(capability: "k8s.read", approval_policy: "confirm", scope: cluster.id)
    coworker_chat = ChatSession.create!(user: owner)
    coworker_chat.define_singleton_method(:coworker) { coworker }
    allow(K8sCluster::AgenticAccess).to receive(:safe_cluster_metadata).and_raise(StandardError, "listing failed")
    allow(K8sCluster::AgenticAudit).to receive(:log!)

    response = described_class.call(server_context: { chat_session: coworker_chat })

    expect(response.error?).to be(true)
    expect(K8sCluster::AgenticAudit).to have_received(:log!).with(hash_including(
      cluster_id: cluster.id,
      context: have_attributes(agent_actor: coworker),
      error: an_instance_of(StandardError)
    ))
  end
end
