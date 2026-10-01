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
        "selector" => { "app" => "web" },
        "ports" => [ { "name" => "http", "port" => 80, "targetPort" => 8080, "protocol" => "TCP" } ]
      }
    }
  end

  describe "#list" do
    it "lists services with port summaries" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/services", { "items" => [ service ] })
      stub_kube_get(
        "#{base}/api/v1/namespaces/default/endpoints",
        {
          "items" => [
            {
              "metadata" => { "name" => "web", "namespace" => "default" },
              "subsets" => [
                {
                  "addresses" => [ { "ip" => "10.0.0.5" }, { "ip" => "10.0.0.6" } ],
                  "notReadyAddresses" => [ { "ip" => "10.0.0.7" } ]
                }
              ]
            }
          ]
        }
      )

      row = described_class.new(cluster).list(namespace: "default")[:services].first

      expect(row[:type]).to eq("ClusterIP")
      expect(row[:cluster_ip]).to eq("10.0.0.10")
      expect(row[:ports]).to eq([ { name: "http", port: 80, target_port: 8080, protocol: "TCP" } ])
      expect(row[:ready_addresses]).to eq(2)
      expect(row[:not_ready_addresses]).to eq(1)
      expect(row[:missing_target_warning]).to be(false)
    end

    it "flags selector-backed services with no ready endpoints" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/services", { "items" => [ service ] })
      stub_kube_get("#{base}/api/v1/namespaces/default/endpoints", { "items" => [] })

      row = described_class.new(cluster).list(namespace: "default")[:services].first

      expect(row[:selector]).to eq("app" => "web")
      expect(row[:missing_target_warning]).to be(true)
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
