require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/kubernetes_clusters/:id/<resource>", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:cluster) { Factories.kubernetes_cluster }

  def parse_body = JSON.parse(response.body)

  def stub_admin_resource_service(service_class, service)
    allow(service_class).to receive(:new).with(
      cluster,
      context: instance_of(McpToolContext),
      tool_name: K8sCluster::ClusterCredential::ADMIN_TOOL_NAME
    ).and_return(service)
  end

  def enable_plugin!
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
  end

  def token_kubeconfig(token: "abc123", server: "https://k8s.example.com:6443")
    <<~YAML
      apiVersion: v1
      kind: Config
      current-context: default
      clusters:
      - name: prod
        cluster:
          server: #{server}
      contexts:
      - name: default
        context:
          cluster: prod
          user: deploy
      users:
      - name: deploy
        user:
          token: #{token}
    YAML
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
      stub_admin_resource_service(
        K8sCluster::Namespaces,
        instance_double(K8sCluster::Namespaces, list: { available: true, generated_at: "2026-09-05T00:00:00Z", namespaces: [ { name: "default" } ] })
      )

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("namespaces", 0, "name")).to eq("default")
    end

    it "lists namespaces for a credential-store-backed cluster through the admin tool policy" do
      credential = CredentialStore::Credential.create!(
        name: "admin-browser-kubeconfig",
        credential_type: K8sCluster::ClusterCredential::CREDENTIAL_TYPE,
        scope_type: "instance",
        created_by: admin,
        owner_user: admin,
        payload: token_kubeconfig(token: "broker-token"),
        safe_metadata: { "cluster" => "prod", "context" => "default", "host" => "k8s.example.com" },
        target_constraints: {},
        allowed_surfaces: %w[admin workflow chat],
        allowed_tools: K8sCluster::ClusterCredential::ALLOWED_TOOLS,
        last_rotated_at: 1.hour.ago
      )
      cluster.update!(credential_store_credential_id: credential.id, api_server_url: "https://k8s.example.com:6443")
      original_factory = K8sCluster::ApiClient.client_factory
      fake_client = double(
        "Kubeclient::Client",
        get_namespaces: {
          "items" => [
            {
              "metadata" => { "name" => "default", "creationTimestamp" => "2026-09-05T00:00:00Z" },
              "status" => { "phase" => "Active" }
            }
          ]
        }
      )
      K8sCluster::ApiClient.client_factory = ->(*) { fake_client }

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("namespaces", 0, "name")).to eq("default")
      expect(CredentialStore::CredentialAccessEvent.last).to have_attributes(
        credential: credential,
        user: admin,
        surface: "admin",
        tool_name: K8sCluster::ClusterCredential::ADMIN_TOOL_NAME,
        result: "allowed"
      )
    ensure
      K8sCluster::ApiClient.client_factory = original_factory if original_factory
    end

    it "describes a namespace when name is given" do
      inspector = instance_double(K8sCluster::Namespaces)
      stub_admin_resource_service(K8sCluster::Namespaces, inspector)
      allow(inspector).to receive(:describe).with("default").and_return(available: true, namespace: { "metadata" => { "name" => "default" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/namespaces", params: { name: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("namespace", "metadata", "name")).to eq("default")
    end

    it "reports a bad gateway when the cluster is unavailable" do
      stub_admin_resource_service(
        K8sCluster::Namespaces,
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
      stub_admin_resource_service(K8sCluster::Pods, pods)
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
      stub_admin_resource_service(K8sCluster::Pods, pods)
      allow(pods).to receive(:describe).with("web-1", namespace: "default").and_return(available: true, pod: { "metadata" => { "name" => "web-1" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pods", params: { name: "web-1", namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("pod", "metadata", "name")).to eq("web-1")
    end

    it "rejects invalid resource identifiers before dispatching to a service" do
      expect(K8sCluster::Pods).not_to receive(:new)

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pods",
        params: { name: "x", namespace: "default/secrets/mysecret?" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_argument")
    end

    it "returns pod logs" do
      pods = instance_double(K8sCluster::Pods)
      stub_admin_resource_service(K8sCluster::Pods, pods)
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
      stub_admin_resource_service(K8sCluster::Deployments, deployments)
      allow(deployments).to receive(:list).with(namespace: nil).and_return(available: true, deployments: [ { name: "web" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/deployments"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("deployments", 0, "name")).to eq("web")
    end

    it "lists services" do
      services = instance_double(K8sCluster::Services)
      stub_admin_resource_service(K8sCluster::Services, services)
      allow(services).to receive(:list).with(namespace: nil).and_return(available: true, services: [ { name: "web" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/services"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("services", 0, "name")).to eq("web")
    end

    it "lists configmaps" do
      config_maps = instance_double(K8sCluster::ConfigMaps)
      stub_admin_resource_service(K8sCluster::ConfigMaps, config_maps)
      allow(config_maps).to receive(:list).with(namespace: nil).and_return(available: true, config_maps: [ { name: "app-settings" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/configmaps"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("config_maps", 0, "name")).to eq("app-settings")
    end

    it "requires a namespace to describe a specific configmap" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/configmaps", params: { name: "app-settings" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end

    it "lists secrets" do
      secrets = instance_double(K8sCluster::Secrets)
      stub_admin_resource_service(K8sCluster::Secrets, secrets)
      allow(secrets).to receive(:list).with(namespace: nil).and_return(available: true, secrets: [ { name: "db-credentials" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/secrets"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("secrets", 0, "name")).to eq("db-credentials")
    end

    it "requires a namespace to describe a specific secret" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/secrets", params: { name: "db-credentials" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end

    it "lists ingresses" do
      ingresses = instance_double(K8sCluster::Ingresses)
      stub_admin_resource_service(K8sCluster::Ingresses, ingresses)
      allow(ingresses).to receive(:list).with(namespace: nil).and_return(available: true, ingresses: [ { name: "web" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/ingresses"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("ingresses", 0, "name")).to eq("web")
    end

    it "requires a namespace to describe a specific ingress" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/ingresses", params: { name: "web" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end

    it "describes an ingress when both name and namespace are given" do
      ingresses = instance_double(K8sCluster::Ingresses)
      stub_admin_resource_service(K8sCluster::Ingresses, ingresses)
      allow(ingresses).to receive(:describe).with("web", namespace: "default").and_return(available: true, ingress: { "metadata" => { "name" => "web" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/ingresses", params: { name: "web", namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("ingress", "metadata", "name")).to eq("web")
    end

    it "lists endpoints" do
      endpoints = instance_double(K8sCluster::Endpoints)
      stub_admin_resource_service(K8sCluster::Endpoints, endpoints)
      allow(endpoints).to receive(:list).with(namespace: nil).and_return(available: true, endpoints: [ { name: "web", ready_addresses: 2 } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/endpoints"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("endpoints", 0, "name")).to eq("web")
    end

    it "lists events" do
      events = instance_double(K8sCluster::Events)
      stub_admin_resource_service(K8sCluster::Events, events)
      allow(events).to receive(:list).with(namespace: nil).and_return(available: true, events: [ { reason: "Scheduled" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/events"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("events", 0, "reason")).to eq("Scheduled")
    end

    it "lists PVCs" do
      pvcs = instance_double(K8sCluster::PersistentVolumeClaims)
      stub_admin_resource_service(K8sCluster::PersistentVolumeClaims, pvcs)
      allow(pvcs).to receive(:list).with(namespace: nil).and_return(available: true, persistent_volume_claims: [ { name: "data" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/pvcs"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("persistent_volume_claims", 0, "name")).to eq("data")
    end

    it "lists nodes" do
      nodes = instance_double(K8sCluster::Nodes)
      stub_admin_resource_service(K8sCluster::Nodes, nodes)
      allow(nodes).to receive(:list).and_return(available: true, nodes: [ { name: "node-1" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/nodes"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("nodes", 0, "name")).to eq("node-1")
    end

    it "lists cronjobs" do
      cron_jobs = instance_double(K8sCluster::CronJobs)
      stub_admin_resource_service(K8sCluster::CronJobs, cron_jobs)
      allow(cron_jobs).to receive(:list).with(namespace: nil).and_return(available: true, cron_jobs: [ { name: "nightly" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/cronjobs"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("cron_jobs", 0, "name")).to eq("nightly")
    end

    it "lists statefulsets" do
      stateful_sets = instance_double(K8sCluster::StatefulSets)
      stub_admin_resource_service(K8sCluster::StatefulSets, stateful_sets)
      allow(stateful_sets).to receive(:list).with(namespace: nil).and_return(available: true, stateful_sets: [ { name: "db" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/statefulsets"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("stateful_sets", 0, "name")).to eq("db")
    end

    it "requires a namespace to describe a specific statefulset" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/statefulsets", params: { name: "db" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end


    it "describes a statefulset when both name and namespace are given" do
      stateful_sets = instance_double(K8sCluster::StatefulSets)
      stub_admin_resource_service(K8sCluster::StatefulSets, stateful_sets)
      allow(stateful_sets).to receive(:describe).with("db", namespace: "default").and_return(available: true, stateful_set: { "metadata" => { "name" => "db" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/statefulsets", params: { name: "db", namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("stateful_set", "metadata", "name")).to eq("db")
    end

    it "lists daemonsets" do
      daemon_sets = instance_double(K8sCluster::DaemonSets)
      stub_admin_resource_service(K8sCluster::DaemonSets, daemon_sets)
      allow(daemon_sets).to receive(:list).with(namespace: nil).and_return(available: true, daemon_sets: [ { name: "monitoring" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/daemonsets"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("daemon_sets", 0, "name")).to eq("monitoring")
    end

    it "requires a namespace to describe a specific daemonset" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/daemonsets", params: { name: "monitoring" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end


    it "describes a daemonset when both name and namespace are given" do
      daemon_sets = instance_double(K8sCluster::DaemonSets)
      stub_admin_resource_service(K8sCluster::DaemonSets, daemon_sets)
      allow(daemon_sets).to receive(:describe).with("monitoring", namespace: "default").and_return(available: true, daemon_set: { "metadata" => { "name" => "monitoring" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/daemonsets", params: { name: "monitoring", namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("daemon_set", "metadata", "name")).to eq("monitoring")
    end

    it "lists jobs" do
      jobs = instance_double(K8sCluster::Jobs)
      stub_admin_resource_service(K8sCluster::Jobs, jobs)
      allow(jobs).to receive(:list).with(namespace: nil).and_return(available: true, jobs: [ { name: "migrate" } ])

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/jobs"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("jobs", 0, "name")).to eq("migrate")
    end

    it "requires a namespace to describe a specific job" do
      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/jobs", params: { name: "migrate" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("namespace_required")
    end

    it "describes a job when both name and namespace are given" do
      jobs = instance_double(K8sCluster::Jobs)
      stub_admin_resource_service(K8sCluster::Jobs, jobs)
      allow(jobs).to receive(:describe).with("migrate", namespace: "default").and_return(available: true, job: { "metadata" => { "name" => "migrate" } })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/jobs", params: { name: "migrate", namespace: "default" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("job", "metadata", "name")).to eq("migrate")
    end

    it "returns the cluster overview" do
      overview = instance_double(K8sCluster::Overview)
      stub_admin_resource_service(K8sCluster::Overview, overview)
      allow(overview).to receive(:call).and_return(nodes: { available: false, reason: "metrics_unavailable" }, pods: { available: false, reason: "metrics_unavailable" })

      get "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/overview"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("nodes", "reason")).to eq("metrics_unavailable")
    end
  end
end
