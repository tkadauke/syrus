require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Secrets do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def secret(name: "db-credentials")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "type" => "Opaque",
      "data" => { "password" => "c3VwZXItc2VjcmV0", "username" => "YWRtaW4=" }
    }
  end

  describe "#list" do
    it "returns metadata only, never secret data values" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/secrets", { "items" => [ secret ] })

      payload = described_class.new(cluster).list(namespace: "default")
      row = payload[:secrets].first

      expect(row[:name]).to eq("db-credentials")
      expect(row[:namespace]).to eq("default")
      expect(row[:type]).to eq("Opaque")
      expect(row[:key_count]).to eq(2)
      expect(row[:key_names]).to eq([ "password", "username" ])
      expect(row[:created_at]).to eq("2026-01-01T00:00:00Z")
      expect(payload.to_json).not_to include("c3VwZXItc2VjcmV0", "YWRtaW4=")
    end
  end

  describe "#describe" do
    it "returns redacted metadata, never secret data values" do
      stub_core_discovery(base)
      stub_kube_get("#{base}/api/v1/namespaces/default/secrets/db-credentials", secret)

      payload = described_class.new(cluster).describe("db-credentials", namespace: "default")

      expect(payload[:secret]).to include(name: "db-credentials", namespace: "default", type: "Opaque")
      expect(payload[:secret][:key_names]).to eq([ "password", "username" ])
      expect(payload.to_json).not_to include("c3VwZXItc2VjcmV0", "YWRtaW4=")
    end
  end
end
