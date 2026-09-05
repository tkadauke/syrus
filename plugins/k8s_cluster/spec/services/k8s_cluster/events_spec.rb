require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Events do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def event(name:, last_timestamp:, reason: "Scheduled")
    {
      "metadata" => { "name" => name, "namespace" => "default" },
      "type" => "Normal",
      "reason" => reason,
      "message" => "message for #{name}",
      "involvedObject" => { "kind" => "Pod", "name" => "web-1" },
      "count" => 1,
      "firstTimestamp" => last_timestamp,
      "lastTimestamp" => last_timestamp
    }
  end

  it "lists events most-recent-first" do
    stub_core_discovery(base)
    stub_kube_get("#{base}/api/v1/namespaces/default/events", {
      "items" => [
        event(name: "old", last_timestamp: "2026-01-01T00:00:00Z"),
        event(name: "new", last_timestamp: "2026-01-02T00:00:00Z")
      ]
    })

    payload = described_class.new(cluster).list(namespace: "default")

    expect(payload[:events].map { |e| e[:name] }).to eq(%w[new old])
    expect(payload[:events].first[:involved_object]).to eq(kind: "Pod", name: "web-1")
  end

  it "raises Unavailable on an API error" do
    stub_kube_error("#{base}/api/v1", 500)

    expect { described_class.new(cluster).list }.to raise_error(K8sCluster::ResourceService::Unavailable)
  end
end
