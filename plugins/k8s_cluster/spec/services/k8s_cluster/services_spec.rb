require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Services do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def service(name: "web")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => {
        "type" => "ClusterIP",
        "clusterIP" => "10.0.0.10",
        "ports" => [ { "name" => "http", "port" => 80, "targetPort" => 8080, "protocol" => "TCP" } ]
      }
    }
  end

  describe "#list" do
    it "lists services with port summaries" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/services", { "items" => [ service ] })

      row = described_class.new(cluster).list(namespace: "default")[:services].first

      expect(row[:type]).to eq("ClusterIP")
      expect(row[:cluster_ip]).to eq("10.0.0.10")
      expect(row[:ports]).to eq([ { name: "http", port: 80, target_port: 8080, protocol: "TCP" } ])
    end
  end

  describe "#describe" do
    it "returns the raw service object" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/services/web", service)

      payload = described_class.new(cluster).describe("web", namespace: "default")

      expect(payload[:service]["metadata"]["name"]).to eq("web")
    end
  end
end
