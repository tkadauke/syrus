require "rails_helper"

RSpec.describe K8sCluster::AgenticAccess do
  describe ".cluster!" do
    it "returns the cluster when agentic access is enabled" do
      cluster = Factories.kubernetes_cluster(agentic_access_enabled: true)

      expect(described_class.cluster!(cluster.id)).to eq(cluster)
    end

    it "raises AccessDisabled when the cluster has not opted in" do
      cluster = Factories.kubernetes_cluster(agentic_access_enabled: false)

      expect { described_class.cluster!(cluster.id) }.to raise_error(described_class::AccessDisabled, /Agentic access is disabled/)
    end

    it "raises ClusterNotFound for an unknown id" do
      expect { described_class.cluster!(-1) }.to raise_error(described_class::ClusterNotFound)
    end
  end

  describe ".cluster_with_write_access!" do
    it "returns the cluster when both agentic access and writes are enabled" do
      cluster = Factories.kubernetes_cluster(agentic_access_enabled: true, allow_writes: true)

      expect(described_class.cluster_with_write_access!(cluster.id)).to eq(cluster)
    end

    it "raises WriteAccessDisabled when writes are off even though agentic access is on" do
      cluster = Factories.kubernetes_cluster(agentic_access_enabled: true, allow_writes: false)

      expect {
        described_class.cluster_with_write_access!(cluster.id)
      }.to raise_error(described_class::WriteAccessDisabled, /Write access is disabled/)
    end

    it "raises AccessDisabled (not WriteAccessDisabled) when agentic access itself is off" do
      cluster = Factories.kubernetes_cluster(agentic_access_enabled: false, allow_writes: true)

      expect {
        described_class.cluster_with_write_access!(cluster.id)
      }.to raise_error(described_class::AccessDisabled, /Agentic access is disabled/)
    end

    it "raises ClusterNotFound for an unknown id" do
      expect { described_class.cluster_with_write_access!(-1) }.to raise_error(described_class::ClusterNotFound)
    end
  end

  describe ".safe_cluster_metadata" do
    it "never includes credentials or the api server URL" do
      Factories.kubernetes_cluster(
        label: "Homelab",
        api_server_url: "https://k3s.internal:6443",
        agentic_access_enabled: true,
        allow_writes: false,
        token: "super-secret-token"
      )

      metadata = described_class.safe_cluster_metadata

      expect(metadata.length).to eq(1)
      expect(metadata.first.keys).to contain_exactly(:id, :label, :agentic_access_enabled, :allow_writes, :created_at, :updated_at)
      expect(metadata.to_s).not_to include("super-secret-token")
      expect(metadata.to_s).not_to include("k3s.internal")
    end
  end
end
