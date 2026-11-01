require "rails_helper"

RSpec.describe K8sCluster::AgenticAccess do
  it "limits interactive and background coworkers to the cluster selected by their k8s.read grant" do
    owner = Factories.user(admin: true)
    granted = Factories.kubernetes_cluster(agentic_access_enabled: true)
    outside_scope = Factories.kubernetes_cluster(agentic_access_enabled: true)
    [ granted, outside_scope ].each do |cluster|
      kubeconfig = K8sCluster::ClusterCredential.build_kubeconfig(
        api_server_url: cluster.api_server_url,
        credentials: { "token" => "broker-only-token" }
      )
      K8sCluster::ClusterCredential.upsert!(cluster: cluster, kubeconfig: kubeconfig, user: owner)
      cluster.save!
    end
    coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Gilfoyle", handle: "gilfoyle-scope",
      workspace_repo: "https://github.com/example/workspace.git")
    [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].each do |role|
      context = McpToolContext.new(surface: role == AgentRole::COWORKER_CHAT ? :chat : :run, role: role, user: owner,
        granted_capabilities: [ "k8s.read" ], capability_scopes: { "k8s.read" => granted.id }, agent_actor: coworker)

      expect(described_class.safe_cluster_metadata(context: context).pluck(:id)).to eq([ granted.id ])
      expect(described_class.cluster!(granted.id, context: context)).to eq(granted)
      expect { described_class.cluster!(outside_scope.id, context: context) }
        .to raise_error(K8sCluster::AgenticAccess::ClusterNotFound, /outside the coworker grant scope/)
    end
  end

  it "never exposes legacy in-record credentials to a coworker" do
    owner = Factories.user(admin: true)
    cluster = Factories.kubernetes_cluster(agentic_access_enabled: true, credentials: { "token" => "legacy-secret" })
    context = McpToolContext.new(surface: :chat, role: AgentRole::COWORKER_CHAT, user: owner,
      granted_capabilities: [ "k8s.read" ], capability_scopes: { "k8s.read" => cluster.id })

    expect(described_class.safe_cluster_metadata(context: context)).to be_empty
    expect { described_class.cluster!(cluster.id, context: context) }.to raise_error(described_class::ClusterNotFound)
  end
end
