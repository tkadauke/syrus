require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Deployments do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def deployment(name: "web")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => { "replicas" => 3 },
      "status" => { "readyReplicas" => 2, "availableReplicas" => 2, "updatedReplicas" => 3 }
    }
  end

  describe "#list" do
    it "lists deployments in a namespace with replica counts" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/namespaces/default/deployments", { "items" => [ deployment ] })

      payload = described_class.new(cluster).list(namespace: "default")

      row = payload[:deployments].first
      expect(row[:name]).to eq("web")
      expect(row[:replicas]).to eq(3)
      expect(row[:ready_replicas]).to eq(2)
      expect(row[:updated_replicas]).to eq(3)
    end

    it "lists across all namespaces when none is given" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/deployments", { "items" => [ deployment ] })

      payload = described_class.new(cluster).list

      expect(payload[:deployments].length).to eq(1)
    end
  end

  describe "#describe" do
    it "returns the raw deployment object" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/namespaces/default/deployments/web", deployment)

      payload = described_class.new(cluster).describe("web", namespace: "default")

      expect(payload[:deployment]["metadata"]["name"]).to eq("web")
    end

    it "raises NotFound for an unknown deployment" do
      stub_apps_discovery(base)
      stub_kube_error("#{base}/apis/apps/v1/namespaces/default/deployments/missing", 404)

      expect {
        described_class.new(cluster).describe("missing", namespace: "default")
      }.to raise_error(K8sCluster::ResourceService::NotFound)
    end
  end
end
