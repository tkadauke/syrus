require "rails_helper"

RSpec.describe K8sCluster::AgenticAccess do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user(admin: false) }
  let(:outsider) { Factories.user(admin: false) }

  def context(user:, surface: :chat, allowed_repository_ids: [])
    McpToolContext.new(surface: surface, role: nil, user: user, allowed_repository_ids: allowed_repository_ids)
  end

  def scoped_cluster(scope_type: "user", scope_id: owner.id, **attributes)
    cluster = Factories.kubernetes_cluster(agentic_access_enabled: true, **attributes)
    credential = CredentialStore::Credential.create!(
      name: "cluster-#{cluster.id}", credential_type: K8sCluster::ClusterCredential::CREDENTIAL_TYPE,
      scope_type: scope_type, scope_id: scope_id, created_by: owner, owner_user: owner,
      payload: "kubeconfig", safe_metadata: {}, target_constraints: {},
      allowed_surfaces: %w[admin workflow chat], allowed_tools: K8sCluster::ClusterCredential::ALLOWED_TOOLS
    )
    cluster.update!(credential_store_credential_id: credential.id, credentials: {})
    cluster
  end

  describe ".cluster!" do
    it "returns the cluster when agentic access is enabled" do
      cluster = scoped_cluster

      expect(described_class.cluster!(cluster.id, context: context(user: owner))).to eq(cluster)
      expect(described_class.cluster!(cluster.id, context: context(user: owner, surface: :run))).to eq(cluster)
    end

    it "raises AccessDisabled when the cluster has not opted in" do
      cluster = scoped_cluster(agentic_access_enabled: false)

      expect { described_class.cluster!(cluster.id, context: context(user: owner)) }.to raise_error(described_class::AccessDisabled, /Agentic access is disabled/)
    end

    it "raises ClusterNotFound for an unknown id" do
      expect { described_class.cluster!(-1, context: context(user: owner)) }.to raise_error(described_class::ClusterNotFound)
    end

    it "makes hidden and legacy clusters nonexistent, while admins see both" do
      cluster = scoped_cluster
      legacy = Factories.kubernetes_cluster(agentic_access_enabled: true, token: "legacy")
      admin = Factories.user(admin: true)

      [ cluster, legacy ].each do |hidden|
        expect { described_class.cluster!(hidden.id, context: context(user: outsider)) }.to raise_error(described_class::ClusterNotFound)
        expect(described_class.cluster!(hidden.id, context: context(user: admin))).to eq(hidden)
      end
    end

    it "honors repository run-token narrowing and team and instance scopes" do
      repository = Factories.repository(user: owner)
      member = Factories.user(admin: false)
      RepositoryMembership.create!(repository: repository, user: member, role: "read")
      repository_cluster = scoped_cluster(scope_type: "repository", scope_id: repository.id)
      team = Team.create!(name: "Cluster operators")
      team.team_memberships.create!(user: member, role: "member")
      team_cluster = scoped_cluster(scope_type: "team", scope_id: team.id)
      instance_cluster = scoped_cluster(scope_type: "instance", scope_id: nil)

      expect(described_class.cluster!(repository_cluster.id, context: context(user: member, surface: :run, allowed_repository_ids: [ repository.id ]))).to eq(repository_cluster)
      expect { described_class.cluster!(repository_cluster.id, context: context(user: member, surface: :run)) }.to raise_error(described_class::ClusterNotFound)
      expect(described_class.cluster!(team_cluster.id, context: context(user: member))).to eq(team_cluster)
      expect(described_class.cluster!(instance_cluster.id, context: context(user: outsider))).to eq(instance_cluster)
    end
  end

  describe ".cluster_with_write_access!" do
    it "returns the cluster when both agentic access and writes are enabled" do
      cluster = scoped_cluster(allow_writes: true)

      expect(described_class.cluster_with_write_access!(cluster.id, context: context(user: owner))).to eq(cluster)
    end

    it "raises WriteAccessDisabled when writes are off even though agentic access is on" do
      cluster = scoped_cluster(allow_writes: false)

      expect {
        described_class.cluster_with_write_access!(cluster.id, context: context(user: owner))
      }.to raise_error(described_class::WriteAccessDisabled, /Write access is disabled/)
    end

    it "raises AccessDisabled (not WriteAccessDisabled) when agentic access itself is off" do
      cluster = scoped_cluster(agentic_access_enabled: false, allow_writes: true)

      expect {
        described_class.cluster_with_write_access!(cluster.id, context: context(user: owner))
      }.to raise_error(described_class::AccessDisabled, /Agentic access is disabled/)
    end

    it "raises ClusterNotFound for an unknown id" do
      expect { described_class.cluster_with_write_access!(-1, context: context(user: owner)) }.to raise_error(described_class::ClusterNotFound)
    end


    it "rejects a scope-hidden write-enabled cluster as not found" do
      cluster = scoped_cluster(allow_writes: true)
      expect { described_class.cluster_with_write_access!(cluster.id, context: context(user: outsider)) }.to raise_error(described_class::ClusterNotFound)
    end
  end

  describe ".safe_cluster_metadata" do
    it "never includes credentials or the api server URL" do
      visible = scoped_cluster(
        label: "Homelab",
        api_server_url: "https://k3s.internal:6443",
        agentic_access_enabled: true,
        allow_writes: false,
        token: "super-secret-token"
      )

      hidden = scoped_cluster(scope_type: "user", scope_id: outsider.id, label: "Hidden")
      expect(owner).not_to be_admin
      expect(K8sCluster::ClusterCredential.credential_for(hidden).scope_id).to eq(outsider.id)
      expect(described_class.usable_by?(hidden, context(user: owner), credential: K8sCluster::ClusterCredential.credential_for(hidden))).to be(false)
      metadata = described_class.safe_cluster_metadata(context: context(user: owner))

      expect(metadata.length).to eq(1)
      expect(metadata.first[:id]).to eq(visible.id)
      expect(metadata.first.keys).to contain_exactly(:id, :label, :agentic_access_enabled, :allow_writes, :created_at, :updated_at)
      expect(metadata.to_s).not_to include("super-secret-token")
      expect(metadata.to_s).not_to include("k3s.internal")
    end
  end
end
