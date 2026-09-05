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
        "capacity" => { "cpu" => "4", "memory" => "16Gi" },
        "allocatable" => { "cpu" => "3800m", "memory" => "15Gi" }
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
      expect(row[:allocatable_cpu]).to eq("3800m")
      expect(row[:allocatable_memory]).to eq("15Gi")
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

  describe "#set_cordon" do
    it "cordons a schedulable node and reports before/after" do
      stub_core_discovery(base)
      url = "#{base}/api/v1/nodes/node-1"
      stub_kube_get(url, node)
      cordoned = node.deep_merge("spec" => { "unschedulable" => true })
      stub_request(:patch, url).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: cordoned.to_json)

      payload = described_class.new(cluster).set_cordon("node-1", cordoned: true)

      expect(payload[:before][:unschedulable]).to be(false)
      expect(payload[:after][:unschedulable]).to be(true)
    end

    it "uncordons a cordoned node" do
      stub_core_discovery(base)
      url = "#{base}/api/v1/nodes/node-1"
      stub_kube_get(url, node.deep_merge("spec" => { "unschedulable" => true }))
      uncordoned = node.deep_merge("spec" => { "unschedulable" => false })
      stub_request(:patch, url).to_return(status: 200, headers: { "Content-Type" => "application/json" }, body: uncordoned.to_json)

      payload = described_class.new(cluster).set_cordon("node-1", cordoned: false)

      expect(payload[:before][:unschedulable]).to be(true)
      expect(payload[:after][:unschedulable]).to be(false)
    end
  end
end
