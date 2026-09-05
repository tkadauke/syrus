require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Nodes do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def node(name: "node-1", ready: true, labels: { "node-role.kubernetes.io/control-plane" => "" })
    {
      "metadata" => { "name" => name, "labels" => labels, "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "status" => {
        "conditions" => [ { "type" => "Ready", "status" => ready ? "True" : "False" } ],
        "addresses" => [ { "type" => "InternalIP", "address" => "192.168.1.10" } ],
        "nodeInfo" => { "kubeletVersion" => "v1.30.0" },
        "capacity" => { "cpu" => "4", "memory" => "16Gi" }
      }
    }
  end

  describe "#list" do
    it "summarizes readiness, roles, and capacity" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/nodes", { "items" => [ node ] })

      row = described_class.new(cluster).list[:nodes].first

      expect(row[:ready]).to be(true)
      expect(row[:roles]).to eq([ "control-plane" ])
      expect(row[:internal_ip]).to eq("192.168.1.10")
      expect(row[:capacity_cpu]).to eq("4")
      expect(row[:capacity_memory]).to eq("16Gi")
    end

    it "reports <none> for a node with no role labels" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/nodes", { "items" => [ node(labels: {}) ] })

      row = described_class.new(cluster).list[:nodes].first

      expect(row[:roles]).to eq([ "<none>" ])
    end

    it "reports not-ready nodes" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/nodes", { "items" => [ node(ready: false) ] })

      row = described_class.new(cluster).list[:nodes].first

      expect(row[:ready]).to be(false)
    end
  end

  describe "#describe" do
    it "returns the raw node object" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/nodes/node-1", node)

      payload = described_class.new(cluster).describe("node-1")

      expect(payload[:node]["metadata"]["name"]).to eq("node-1")
    end
  end
end
