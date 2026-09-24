require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::DaemonSets do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def daemon_set(name: "monitoring")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "status" => {
        "desiredNumberScheduled" => 3,
        "currentNumberScheduled" => 3,
        "numberReady" => 2,
        "numberAvailable" => 2
      }
    }
  end

  describe "#list" do
    it "lists daemon sets with scheduled/ready counts" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/namespaces/default/daemonsets", { "items" => [ daemon_set ] })

      row = described_class.new(cluster).list(namespace: "default")[:daemon_sets].first

      expect(row[:name]).to eq("monitoring")
      expect(row[:desired_number_scheduled]).to eq(3)
      expect(row[:current_number_scheduled]).to eq(3)
      expect(row[:number_ready]).to eq(2)
      expect(row[:number_available]).to eq(2)
    end

    it "lists across all namespaces when none is given" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/daemonsets", { "items" => [ daemon_set ] })

      payload = described_class.new(cluster).list

      expect(payload[:daemon_sets].length).to eq(1)
    end
  end

  describe "#describe" do
    it "returns the raw daemon set object" do
      stub_apps_discovery(base)
      stub_kube_get("#{base}/apis/apps/v1/namespaces/default/daemonsets/monitoring", daemon_set)

      payload = described_class.new(cluster).describe("monitoring", namespace: "default")

      expect(payload[:daemon_set]["metadata"]["name"]).to eq("monitoring")
    end

    it "raises NotFound for an unknown daemon set" do
      stub_apps_discovery(base)
      stub_kube_error("#{base}/apis/apps/v1/namespaces/default/daemonsets/missing", 404)

      expect {
        described_class.new(cluster).describe("missing", namespace: "default")
      }.to raise_error(K8sCluster::ResourceService::NotFound)
    end
  end
end
