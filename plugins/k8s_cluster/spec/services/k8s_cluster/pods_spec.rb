require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Pods do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def pod(name: "web-1", namespace: "default", phase: "Running", ready_count: 1, container_count: 1, restart_count: 0)
    statuses = Array.new(ready_count) { { "ready" => true, "restartCount" => restart_count } } +
      Array.new(container_count - ready_count) { { "ready" => false, "restartCount" => restart_count } }

    {
      "metadata" => { "name" => name, "namespace" => namespace, "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => { "nodeName" => "node-1", "containers" => Array.new(container_count) { { "name" => "app" } } },
      "status" => { "phase" => phase, "podIP" => "10.0.0.5", "containerStatuses" => statuses }
    }
  end

  describe "#list" do
    it "lists pods across all namespaces when no namespace is given" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/pods", { "items" => [ pod, pod(name: "web-2", namespace: "other") ] })

      payload = described_class.new(cluster).list

      expect(payload[:available]).to be(true)
      expect(payload[:pods].length).to eq(2)
    end

    it "scopes to a namespace when one is given" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/pods", { "items" => [ pod ] })

      payload = described_class.new(cluster).list(namespace: "default")

      expect(payload[:pods].first[:namespace]).to eq("default")
    end

    it "summarizes readiness and restart counts across containers" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/pods", { "items" => [ pod(ready_count: 1, container_count: 2, restart_count: 3) ] })

      summary = described_class.new(cluster).list[:pods].first

      expect(summary[:ready]).to eq("1/2")
      expect(summary[:restart_count]).to eq(6)
      expect(summary[:node_name]).to eq("node-1")
    end
  end

  describe "#describe" do
    it "returns the raw pod object" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/pods/web-1", pod)

      payload = described_class.new(cluster).describe("web-1", namespace: "default")

      expect(payload[:pod]["metadata"]["name"]).to eq("web-1")
    end
  end

  describe "#logs" do
    it "returns the raw log tail for a pod" do
      stub_core_discovery(base)
      stub_kube_text("#{base}/api/v1/namespaces/default/pods/web-1/log?tailLines=200", "line one\nline two\n")

      payload = described_class.new(cluster).logs("web-1", namespace: "default")

      expect(payload[:log]).to eq("line one\nline two\n")
      expect(payload[:pod]).to eq("web-1")
    end

    it "passes the container param for multi-container pods" do
      stub_core_discovery(base)
      stub_kube_text("#{base}/api/v1/namespaces/default/pods/web-1/log?container=sidecar&tailLines=50", "sidecar logs\n")

      payload = described_class.new(cluster).logs("web-1", namespace: "default", container: "sidecar", tail_lines: 50)

      expect(payload[:log]).to eq("sidecar logs\n")
      expect(payload[:container]).to eq("sidecar")
    end

    it "raises Unavailable when the pod cannot be reached" do
      stub_core_discovery(base)
      stub_request(:get, "#{base}/api/v1/namespaces/default/pods/web-1/log?tailLines=200").to_return(status: 502)

      expect { described_class.new(cluster).logs("web-1", namespace: "default") }.to raise_error(K8sCluster::ResourceService::Unavailable)
    end
  end
end
