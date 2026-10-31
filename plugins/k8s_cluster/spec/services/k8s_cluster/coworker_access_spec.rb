require "rails_helper"

RSpec.describe K8sCluster::AgenticAccess do
  it "limits interactive and background coworkers to the cluster selected by their k8s.read grant" do
    owner = Factories.user(admin: true)
    granted = Factories.kubernetes_cluster(agentic_access_enabled: true)
    outside_scope = Factories.kubernetes_cluster(agentic_access_enabled: true)
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
end
