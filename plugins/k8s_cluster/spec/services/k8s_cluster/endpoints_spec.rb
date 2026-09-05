require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Endpoints do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def endpoint(name: "web", ready_addresses: [ { "ip" => "10.0.0.5" } ], not_ready_addresses: [])
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "subsets" => [
        {
          "addresses" => ready_addresses,
          "notReadyAddresses" => not_ready_addresses,
          "ports" => [ { "name" => "http", "port" => 8080, "protocol" => "TCP" } ]
        }
      ]
    }
  end

  describe "#list" do
    it "counts ready and not-ready addresses across subsets" do
      stub_core_discovery(base)
      stub_kube_get(
        "#{base}/api/v1/namespaces/default/endpoints",
        { "items" => [ endpoint(ready_addresses: [ { "ip" => "10.0.0.5" }, { "ip" => "10.0.0.6" } ], not_ready_addresses: [ { "ip" => "10.0.0.7" } ]) ] }
      )

      row = described_class.new(cluster).list(namespace: "default")[:endpoints].first

      expect(row[:ready_addresses]).to eq(2)
      expect(row[:not_ready_addresses]).to eq(1)
      expect(row[:ports]).to eq([ { name: "http", port: 8080, protocol: "TCP" } ])
    end

    it "reports zero addresses for a Service with no backing pods" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/endpoints", { "items" => [ endpoint(ready_addresses: []) ] })

      row = described_class.new(cluster).list(namespace: "default")[:endpoints].first

      expect(row[:ready_addresses]).to eq(0)
      expect(row[:not_ready_addresses]).to eq(0)
    end

    it "shares its name with the Service it backs" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/endpoints", { "items" => [ endpoint(name: "web") ] })

      row = described_class.new(cluster).list(namespace: "default")[:endpoints].first

      expect(row[:name]).to eq("web")
      expect(row[:namespace]).to eq("default")
    end
  end

  describe "#describe" do
    it "returns the raw endpoints object" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/endpoints/web", endpoint)

      payload = described_class.new(cluster).describe("web", namespace: "default")

      expect(payload[:endpoint]["metadata"]["name"]).to eq("web")
    end
  end
end
