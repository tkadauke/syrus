require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Jobs do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def job(name: "migrate")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => { "completions" => 1, "parallelism" => 1 },
      "status" => { "active" => [ { "name" => "migrate-123" } ], "succeeded" => 0, "failed" => 0 }
    }
  end

  describe "#list" do
    it "lists jobs with completions and active counts" do
      stub_batch_discovery(base)
      stub_kube_get("#{base}/apis/batch/v1/namespaces/default/jobs", { "items" => [ job ] })

      row = described_class.new(cluster).list(namespace: "default")[:jobs].first

      expect(row[:name]).to eq("migrate")
      expect(row[:completions]).to eq(1)
      expect(row[:parallelism]).to eq(1)
      expect(row[:active_count]).to eq(1)
      expect(row[:succeeded]).to eq(0)
      expect(row[:failed]).to eq(0)
    end

    it "lists across all namespaces when none is given" do
      stub_batch_discovery(base)
      stub_kube_get("#{base}/apis/batch/v1/jobs", { "items" => [ job ] })

      payload = described_class.new(cluster).list

      expect(payload[:jobs].length).to eq(1)
    end
  end

  describe "#describe" do
    it "returns the raw job object" do
      stub_batch_discovery(base)
      stub_kube_get("#{base}/apis/batch/v1/namespaces/default/jobs/migrate", job)

      payload = described_class.new(cluster).describe("migrate", namespace: "default")

      expect(payload[:job]["metadata"]["name"]).to eq("migrate")
    end

    it "raises NotFound for an unknown job" do
      stub_batch_discovery(base)
      stub_kube_error("#{base}/apis/batch/v1/namespaces/default/jobs/missing", 404)

      expect {
        described_class.new(cluster).describe("missing", namespace: "default")
      }.to raise_error(K8sCluster::ResourceService::NotFound)
    end
  end
end
