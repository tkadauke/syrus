require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::PersistentVolumeClaims do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def pvc(name: "data")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => { "storageClassName" => "standard", "accessModes" => [ "ReadWriteOnce" ], "volumeName" => "pvc-123" },
      "status" => { "phase" => "Bound", "capacity" => { "storage" => "5Gi" } }
    }
  end

  describe "#list" do
    it "lists PVCs with capacity and status" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/persistentvolumeclaims", { "items" => [ pvc ] })

      row = described_class.new(cluster).list(namespace: "default")[:persistent_volume_claims].first

      expect(row[:status]).to eq("Bound")
      expect(row[:capacity]).to eq("5Gi")
      expect(row[:access_modes]).to eq([ "ReadWriteOnce" ])
    end
  end

  describe "#describe" do
    it "returns the raw PVC object" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/persistentvolumeclaims/data", pvc)

      payload = described_class.new(cluster).describe("data", namespace: "default")

      expect(payload[:persistent_volume_claim]["metadata"]["name"]).to eq("data")
    end
  end
end
