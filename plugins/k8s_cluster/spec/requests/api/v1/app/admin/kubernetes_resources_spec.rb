require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/kubernetes_clusters/:id/<resource>", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:cluster) { Factories.kubernetes_cluster }

  def parse_body = JSON.parse(response.body)

  def enable_plugin!
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
  end

  it "is disabled by default (plugin disabled)" do
    sign_in_as(admin)

    get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "rejects non-admins" do
    enable_plugin!
    sign_in_as(member)

    get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  describe "as an admin with the plugin enabled" do
    before do
      enable_plugin!
      sign_in_as(admin)
    end

    it "404s for an unknown cluster id" do
      get "/api/v1/app/admin/kubernetes_clusters/999999/namespaces"

      expect(response).to have_http_status(:not_found)
    end

    it "lists namespaces" do
      allow(K8sCluster::Namespaces).to receive(:new).with(cluster).and_return(
        instance_double(K8sCluster::Namespaces, list: { available: true, generated_at: "2026-09-05T00:00:00Z", namespaces: [ { name: "default" } ] })
      )

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("namespaces", 0, "name")).to eq("default")
    end

    it "describes a namespace when name is given" do
      inspector = instance_double(K8sCluster::Namespaces)
      allow(K8sCluster::Namespaces).to receive(:new).with(cluster).and_return(inspector)
      allow(inspector).to receive(:describe).with("default").and_return(available: true, namespace: { "metadata" => { "name" => "default" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces", params: { name: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("namespace", "metadata", "name")).to eq("default")
    end

    it "reports a bad gateway when the cluster is unavailable" do
      allow(K8sCluster::Namespaces).to receive(:new).with(cluster).and_return(
        instance_double(K8sCluster::Namespaces).tap do |inspector|
          allow(inspector).to receive(:list).and_raise(K8sCluster::ResourceService::Unavailable, "connection refused")
        end
      )

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces"

      expect(response).to have_http_status(:bad_gateway)
      expect(parse_body.dig("error", "code")).to eq("connection_unavailable")
    end

    it "lists pods scoped to a namespace" do
      pods = instance_double(K8sCluster::Pods)
      allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(pods)
      allow(pods).to receive(:list).with(namespace: "default").and_return(available: true, pods: [ { name: "web-1" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pods", params: { namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("pods", 0, "name")).to eq("web-1")
    end

    it "requires a namespace to describe a specific pod" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pods", params: { name: "web-1" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end

    it "describes a pod when both name and namespace are given" do
      pods = instance_double(K8sCluster::Pods)
      allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(pods)
      allow(pods).to receive(:describe).with("web-1", namespace: "default").and_return(available: true, pod: { "metadata" => { "name" => "web-1" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pods", params: { name: "web-1", namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("pod", "metadata", "name")).to eq("web-1")
    end

    it "returns pod logs" do
      pods = instance_double(K8sCluster::Pods)
      allow(K8sCluster::Pods).to receive(:new).with(cluster).and_return(pods)
      allow(pods).to receive(:logs).with("web-1", namespace: "default", container: nil, tail_lines: 200, previous: false, timestamps: false)
        .and_return(available: true, log: "log output\n")

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pods/web-1/logs", params: { namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body["log"]).to eq("log output\n")
    end

    it "requires a namespace for pod logs" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pods/web-1/logs"

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end

    it "lists deployments" do
      deployments = instance_double(K8sCluster::Deployments)
      allow(K8sCluster::Deployments).to receive(:new).with(cluster).and_return(deployments)
      allow(deployments).to receive(:list).with(namespace: nil).and_return(available: true, deployments: [ { name: "web" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/deployments"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("deployments", 0, "name")).to eq("web")
    end

    it "lists services" do
      services = instance_double(K8sCluster::Services)
      allow(K8sCluster::Services).to receive(:new).with(cluster).and_return(services)
      allow(services).to receive(:list).with(namespace: nil).and_return(available: true, services: [ { name: "web" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/services"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("services", 0, "name")).to eq("web")
    end

    it "lists events" do
      events = instance_double(K8sCluster::Events)
      allow(K8sCluster::Events).to receive(:new).with(cluster).and_return(events)
      allow(events).to receive(:list).with(namespace: nil).and_return(available: true, events: [ { reason: "Scheduled" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/events"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("events", 0, "reason")).to eq("Scheduled")
    end

    it "lists PVCs" do
      pvcs = instance_double(K8sCluster::PersistentVolumeClaims)
      allow(K8sCluster::PersistentVolumeClaims).to receive(:new).with(cluster).and_return(pvcs)
      allow(pvcs).to receive(:list).with(namespace: nil).and_return(available: true, persistent_volume_claims: [ { name: "data" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pvcs"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("persistent_volume_claims", 0, "name")).to eq("data")
    end

    it "lists nodes" do
      nodes = instance_double(K8sCluster::Nodes)
      allow(K8sCluster::Nodes).to receive(:new).with(cluster).and_return(nodes)
      allow(nodes).to receive(:list).and_return(available: true, nodes: [ { name: "node-1" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/nodes"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("nodes", 0, "name")).to eq("node-1")
    end

    it "lists cronjobs" do
      cron_jobs = instance_double(K8sCluster::CronJobs)
      allow(K8sCluster::CronJobs).to receive(:new).with(cluster).and_return(cron_jobs)
      allow(cron_jobs).to receive(:list).with(namespace: nil).and_return(available: true, cron_jobs: [ { name: "nightly" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/cronjobs"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("cron_jobs", 0, "name")).to eq("nightly")
    end

    it "returns the cluster overview" do
      overview = instance_double(K8sCluster::Overview)
      allow(K8sCluster::Overview).to receive(:new).with(cluster).and_return(overview)
      allow(overview).to receive(:call).and_return(nodes: { available: false, reason: "metrics_unavailable" }, pods: { available: false, reason: "metrics_unavailable" })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/overview"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("nodes", "reason")).to eq("metrics_unavailable")
    end
  end
end
