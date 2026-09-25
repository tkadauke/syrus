require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::ConfigMaps do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def config_map(name: "app-settings")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "data" => { "log_level" => "info", "feature_flags" => "a,b" },
      "binaryData" => { "blob.bin" => "AAEC" }
    }
  end

  describe "#list" do
    it "lists config maps with key metadata" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/configmaps", { "items" => [ config_map ] })

      row = described_class.new(cluster).list(namespace: "default")[:config_maps].first

      expect(row[:name]).to eq("app-settings")
      expect(row[:namespace]).to eq("default")
      expect(row[:key_count]).to eq(3)
      expect(row[:key_names]).to eq([ "blob.bin", "feature_flags", "log_level" ])
      expect(row[:created_at]).to eq("2026-01-01T00:00:00Z")
    end
  end

  describe "#describe" do
    it "returns the raw config map object" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/configmaps/app-settings", config_map)

      payload = described_class.new(cluster).describe("app-settings", namespace: "default")

      expect(payload[:config_map]["metadata"]["name"]).to eq("app-settings")
    end
  end
end
