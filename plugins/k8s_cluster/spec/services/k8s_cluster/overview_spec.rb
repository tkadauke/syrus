require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Overview do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443/apis/metrics.k8s.io/v1beta1" }

  it "aggregates node and pod CPU/memory usage" do
    stub_kube_get("#{base}/nodes", {
      "items" => [
        { "metadata" => { "name" => "node-1" }, "usage" => { "cpu" => "250m", "memory" => "512Mi" } },
        { "metadata" => { "name" => "node-2" }, "usage" => { "cpu" => "500m", "memory" => "1Gi" } }
      ]
    })
    stub_kube_get("#{base}/pods", {
      "items" => [
        {
          "metadata" => { "name" => "web-1", "namespace" => "default" },
          "containers" => [ { "name" => "app", "usage" => { "cpu" => "100m", "memory" => "128Mi" } } ]
        }
      ]
    })

    payload = described_class.new(cluster).call

    expect(payload[:nodes][:available]).to be(true)
    expect(payload[:nodes][:total_cpu_millicores]).to eq(750)
    expect(payload[:nodes][:total_memory_bytes]).to eq(512 * 1024 * 1024 + 1024**3)
    expect(payload[:pods][:available]).to be(true)
    expect(payload[:pods][:items].first[:name]).to eq("web-1")
    expect(payload[:pods][:total_cpu_millicores]).to eq(100)
  end

  it "soft-fails when metrics-server is not installed (404 from the API server)" do
    stub_kube_error("#{base}/nodes", 404)
    stub_kube_error("#{base}/pods", 404)

    payload = described_class.new(cluster).call

    expect(payload[:nodes]).to eq(available: false, reason: "metrics_unavailable", message: "404 Not Found")
    expect(payload[:pods][:available]).to be(false)
  end

  it "soft-fails on a connection error rather than raising" do
    stub_request(:get, "#{base}/nodes").to_timeout
    stub_request(:get, "#{base}/pods").to_timeout

    expect { described_class.new(cluster).call }.not_to raise_error

    payload = described_class.new(cluster).call
    expect(payload[:nodes][:available]).to be(false)
    expect(payload[:nodes][:reason]).to eq("metrics_unavailable")
  end
end
