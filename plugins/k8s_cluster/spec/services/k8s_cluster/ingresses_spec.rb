require "rails_helper"
require_relative "../../support/kube_api_stubs"

RSpec.describe K8sCluster::Ingresses do
  include KubeApiStubs

  let(:cluster) { Factories.kubernetes_cluster(api_server_url: "https://k8s.example.com:6443") }
  let(:base) { "https://k8s.example.com:6443" }

  def ingress(name: "web")
    {
      "metadata" => { "name" => name, "namespace" => "default", "creationTimestamp" => "2026-01-01T00:00:00Z" },
      "spec" => {
        "ingressClassName" => "nginx",
        "tls" => [ { "hosts" => [ "web.example.com" ] } ],
        "rules" => [
          {
            "host" => "web.example.com",
            "http" => {
              "paths" => [
                {
                  "path" => "/",
                  "pathType" => "Prefix",
                  "backend" => { "service" => { "name" => "web", "port" => { "number" => 80 } } }
                }
              ]
            }
          }
        ]
      }
    }
  end

  describe "#list" do
    it "lists ingresses with hosts, backend service/port, TLS hosts, and ingress class" do
      stub_networking_discovery(base)
      stub_kube_get("#{base}/apis/networking.k8s.io/v1/namespaces/default/ingresses", { "items" => [ ingress ] })

      row = described_class.new(cluster).list(namespace: "default")[:ingresses].first

      expect(row[:name]).to eq("web")
      expect(row[:ingress_class]).to eq("nginx")
      expect(row[:hosts]).to eq([ "web.example.com" ])
      expect(row[:tls_hosts]).to eq([ "web.example.com" ])
      expect(row[:rules].first[:paths].first).to include(service_name: "web", service_port: 80)
    end

    it "lists across all namespaces when none is given" do
      stub_networking_discovery(base)
      stub_kube_get("#{base}/apis/networking.k8s.io/v1/ingresses", { "items" => [ ingress ] })

      payload = described_class.new(cluster).list

      expect(payload[:ingresses].length).to eq(1)
    end

    it "handles ingresses without rules or TLS" do
      stub_networking_discovery(base)
      bare = ingress.merge("spec" => {})
      stub_kube_get("#{base}/apis/networking.k8s.io/v1/namespaces/default/ingresses", { "items" => [ bare ] })

      row = described_class.new(cluster).list(namespace: "default")[:ingresses].first

      expect(row[:hosts]).to eq([])
      expect(row[:rules]).to eq([])
      expect(row[:tls_hosts]).to eq([])
      expect(row[:ingress_class]).to be_nil
    end

    it "supports named service ports" do
      stub_networking_discovery(base)
      named = ingress
      named["spec"]["rules"][0]["http"]["paths"][0]["backend"] = { "service" => { "name" => "web", "port" => { "name" => "http" } } }
      stub_kube_get("#{base}/apis/networking.k8s.io/v1/namespaces/default/ingresses", { "items" => [ named ] })

      row = described_class.new(cluster).list(namespace: "default")[:ingresses].first

      expect(row[:rules].first[:paths].first).to include(service_name: "web", service_port: "http")
    end
  end

  describe "#describe" do
    it "returns the raw ingress object" do
      stub_networking_discovery(base)
      stub_kube_get("#{base}/apis/networking.k8s.io/v1/namespaces/default/ingresses/web", ingress)

      payload = described_class.new(cluster).describe("web", namespace: "default")

      expect(payload[:ingress]["metadata"]["name"]).to eq("web")
    end

    it "raises NotFound for an unknown ingress" do
      stub_networking_discovery(base)
      stub_kube_error("#{base}/apis/networking.k8s.io/v1/namespaces/default/ingresses/missing", 404)

      expect {
        described_class.new(cluster).describe("missing", namespace: "default")
      }.to raise_error(K8sCluster::ResourceService::NotFound)
    end
  end
end
