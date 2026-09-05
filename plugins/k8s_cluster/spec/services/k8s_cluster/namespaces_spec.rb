require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Namespaces do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  describe "#list" do
    it "lists namespaces with their phase" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces", {
        "items" => [
          { "metadata" => { "name" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" }, "status" => { "phase" => "Active" } },
          { "metadata" => { "name" => "kube-system", "creationTimestamp" => "2026-01-01T00:00:00Z" }, "status" => { "phase" => "Active" } }
        ]
      })

      payload = described_class.new(cluster).list

      expect(payload[:available]).to be(true)
      expect(payload[:namespaces].map { |ns| ns[:name] }).to eq(%w[default kube-system])
      expect(payload[:namespaces].first[:status]).to eq("Active")
    end

    it "raises Unavailable when the cluster cannot be reached" do
      stub_request(:get, "#{base}/api/v1").to_timeout

      expect { described_class.new(cluster).list }.to raise_error(K8sCluster::ResourceService::Unavailable)
    end

    it "raises Unavailable on an HTTP error from the API server" do
      stub_kube_error("#{base}/api/v1", 401)

      expect { described_class.new(cluster).list }.to raise_error(K8sCluster::ResourceService::Unavailable)
    end
  end

  describe "#describe" do
    it "returns the raw namespace object" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default", { "metadata" => { "name" => "default" }, "status" => { "phase" => "Active" } })

      payload = described_class.new(cluster).describe("default")

      expect(payload[:namespace]["metadata"]["name"]).to eq("default")
    end

    it "raises NotFound for an unknown namespace" do
      stub_core_discovery(base)
      stub_kube_error("#{base}/api/v1/namespaces/missing", 404)

      expect { described_class.new(cluster).describe("missing") }.to raise_error(K8sCluster::ResourceService::NotFound)
    end
  end
end
