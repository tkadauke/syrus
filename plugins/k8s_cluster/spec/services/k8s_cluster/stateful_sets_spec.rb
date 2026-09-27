require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::StatefulSets do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def stateful_set(name: "db")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => { "replicas" => 3 },
      "status" => { "readyReplicas" => 2, "currentReplicas" => 2, "updatedReplicas" => 3 }
    }
  end

  describe "#list" do
    it "lists stateful sets with ready/desired replica counts" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/namespaces/default/statefulsets", { "items" => [ stateful_set ] })

      row = described_class.new(cluster).list(namespace: "default")[:stateful_sets].first

      expect(row[:name]).to eq("db")
      expect(row[:replicas]).to eq(3)
      expect(row[:ready_replicas]).to eq(2)
      expect(row[:current_replicas]).to eq(2)
      expect(row[:updated_replicas]).to eq(3)
    end

    it "lists across all namespaces when none is given" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/statefulsets", { "items" => [ stateful_set ] })

      payload = described_class.new(cluster).list

      expect(payload[:stateful_sets].length).to eq(1)
    end
  end

  describe "#describe" do
    it "returns the raw stateful set object" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/namespaces/default/statefulsets/db", stateful_set)

      payload = described_class.new(cluster).describe("db", namespace: "default")

      expect(payload[:stateful_set]["metadata"]["name"]).to eq("db")
    end

    it "raises NotFound for an unknown stateful set" do
      stub_apps_discovery(base)
      stub_kube_error("#{base}/apis/apps/v1/namespaces/default/statefulsets/missing", 404)

      expect {
        described_class.new(cluster).describe("missing", namespace: "default")
      }.to raise_error(K8sCluster::ResourceService::NotFound)
    end
  end
end
