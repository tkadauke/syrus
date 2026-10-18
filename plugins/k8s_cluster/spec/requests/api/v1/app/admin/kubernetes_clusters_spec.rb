require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/kubernetes_clusters", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }

  def parse_body = JSON.parse(response.body)

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      queries << payload[:sql].to_s
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def enable_plugin!
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
  end

  def token_kubeconfig(token: "abc123", server: "https://k8s.example.com:6443")
    <<~YAML
      current-context: default
      clusters:
        - name: my-cluster
          cluster:
            server: #{server}
      users:
        - name: my-user
          user:
            token: #{token}
      contexts:
        - name: default
          context:
            cluster: my-cluster
            user: my-user
    YAML
  end

  def jwt(expiry)
    [ { alg: "none" }, { exp: expiry.to_i }, "" ].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }.join(".")
  end

  it "is disabled by default (plugin disabled)" do
    sign_in_as(admin)

    get "/api/v1/app/admin/kubernetes_clusters"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "rejects non-admins" do
    enable_plugin!
    sign_in_as(member)

    get "/api/v1/app/admin/kubernetes_clusters"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  describe "as an admin with the plugin enabled" do
    before do
      enable_plugin!
      sign_in_as(admin)
    end

    it "lists clusters without exposing credentials" do
      Factories.kubernetes_cluster(label: "Staging").tap do |cluster|
        cluster.token = "s3cret-token"
        cluster.credential_kind = "token"
        cluster.save!
      end

      get "/api/v1/app/admin/kubernetes_clusters"

      expect(response).to have_http_status(:ok)
      cluster = parse_body.fetch("kubernetes_clusters").first
      expect(cluster["label"]).to eq("Staging")
      expect(cluster["credential_kind"]).to eq("token")
      expect(cluster).not_to have_key("credentials")
      expect(cluster).not_to have_key("token")
      expect(response.body).not_to include("s3cret-token")
    end

    it "lists broker-backed clusters without reading credential payloads" do
      credential = CredentialStore::Credential.create!(
        name: "staging-kubeconfig",
        credential_type: "k8s_cluster.kubeconfig",
        scope_type: "instance",
        created_by: admin,
        owner_user: admin,
        payload: token_kubeconfig(token: "s3cret-token"),
        safe_metadata: { "cluster" => "my-cluster", "context" => "default", "host" => "k8s.example.com" },
        target_constraints: {},
        allowed_surfaces: %w[admin workflow chat],
        allowed_tools: [],
        expires_at: 10.minutes.from_now,
        last_rotated_at: 1.hour.ago
      )
      Factories.kubernetes_cluster(label: "Staging", credential_store_credential_id: credential.id, credential_kind: "token")
      expect(CredentialStore::Credential).not_to receive(:find_by)

      get "/api/v1/app/admin/kubernetes_clusters"

      expect(response).to have_http_status(:ok)
      cluster = parse_body.fetch("kubernetes_clusters").first
      expect(cluster["credential_kind"]).to eq("token")
      expect(cluster["credential_health"]).to eq("expiring")
      expect(cluster["credential_expires_at"]).to eq(credential.expires_at.iso8601)
      expect(response.body).not_to include("s3cret-token")
    end

    it "preloads team membership counts for credential scope options" do
      3.times do |index|
        team = Team.create!(name: "Team #{index}")
        team.team_memberships.create!(user: Factories.user(admin: false), role: "member")
      end

      queries = capture_sql { get "/api/v1/app/admin/kubernetes_clusters" }

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("credential_scope_options", "teams").pluck("detail")).to all(eq("1 members"))
      expect(queries.grep(/COUNT\([^)]*\).*team_memberships/i)).to be_empty
      expect(queries.grep(/FROM ["`]?team_memberships["`]?/i).size).to eq(1)
    end

    it "creates a cluster by parsing a pasted kubeconfig" do
      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "Prod", kubeconfig: token_kubeconfig(token: "hunter2") }
      }

      expect(response).to have_http_status(:created)
      expect(response.body).not_to include("hunter2")

      cluster = KubernetesCluster.find(parse_body.dig("kubernetes_cluster", "id"))
      expect(cluster.api_server_url).to eq("https://k8s.example.com:6443")
      expect(cluster.token).to be_nil
      expect(cluster.credential_store_credential_id).to be_present
      expect(cluster.credential_kind).to eq("token")
      expect(cluster.agentic_access_enabled).to be false

      credential = CredentialStore::Credential.find(cluster.credential_store_credential_id)
      expect(credential).to have_attributes(
        credential_type: "k8s_cluster.kubeconfig",
        scope_type: "instance",
        created_by: admin
      )
      expect(credential.payload).to include("hunter2")
      expect(credential.safe_metadata).to include("cluster" => "my-cluster", "context" => "default", "host" => "k8s.example.com")
      expect(credential.target_constraints).to eq({})
      expect(credential.allowed_surfaces).to match_array(%w[admin workflow chat])
      expect(credential.allowed_tools).to match_array(K8sCluster::ClusterCredential::ALLOWED_TOOLS)
      expect(credential.allowed_tools).not_to include("credential.exec")
    end

    it "persists an authorized backing credential scope and exposes manageable options" do
      repository = Factories.repository(user: admin)

      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: {
          label: "Repo cluster", kubeconfig: token_kubeconfig,
          credential_scope_type: "repository", credential_scope_id: repository.id
        }
      }

      expect(response).to have_http_status(:created)
      cluster = KubernetesCluster.find(parse_body.dig("kubernetes_cluster", "id"))
      credential = CredentialStore::Credential.find(cluster.credential_store_credential_id)
      expect(credential).to have_attributes(scope_type: "repository", scope_id: repository.id)

      get "/api/v1/app/admin/kubernetes_clusters"
      expect(parse_body.fetch("credential_scope_options").fetch("scopes").pluck("value")).to include("user", "repository", "instance")
      expect(parse_body.fetch("kubernetes_clusters").first).to include(
        "credential_scope_type" => "repository", "credential_scope_id" => repository.id, "legacy_credentials" => false
      )
    end

    it "rejects creation without a kubeconfig" do
      post "/api/v1/app/admin/kubernetes_clusters", params: { kubernetes_cluster: { label: "Prod" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(KubernetesCluster.count).to eq(0)
    end

    it "rejects creation with an unparsable kubeconfig" do
      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "Prod", kubeconfig: "not: [valid" }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(KubernetesCluster.count).to eq(0)
    end

    it "rejects creation when the kubeconfig server is not a URL" do
      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "Prod", kubeconfig: token_kubeconfig(server: "not a url") }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to match(/valid HTTP\(S\) URL/)
      expect(KubernetesCluster.count).to eq(0)
      expect(CredentialStore::Credential.count).to eq(0)
    end

    it "rejects invalid params" do
      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "", kubeconfig: token_kubeconfig }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(KubernetesCluster.count).to eq(0)
    end

    it "updates a cluster's label without requiring a new kubeconfig" do
      cluster = Factories.kubernetes_cluster(label: "Old label")
      expect_any_instance_of(KubernetesCluster).to receive(:with_lock).and_call_original

      patch "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}", params: {
        kubernetes_cluster: { label: "Renamed" }
      }

      expect(response).to have_http_status(:ok)
      expect(cluster.reload.label).to eq("Renamed")
    end

    it "serializes manual rotation with automatic refresh and audits the operator" do
      cluster = Factories.kubernetes_cluster(label: "Old label")
      K8sCluster::ClusterCredential.upsert!(cluster: cluster, kubeconfig: token_kubeconfig, user: admin)
      cluster.save!
      CredentialStore::CredentialAccessEvent.delete_all
      expect_any_instance_of(KubernetesCluster).to receive(:with_lock).and_call_original

      patch "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}", params: {
        kubernetes_cluster: { kubeconfig: token_kubeconfig(token: "replacement") }
      }

      expect(response).to have_http_status(:ok)
      event = CredentialStore::CredentialAccessEvent.find_by!(action: "rotate")
      expect(event).to have_attributes(user: admin, surface: "admin", result: "allowed")
      expect(event.metadata).to include("payload_replaced" => true, "source" => "k8s_cluster")
    end

    it "rejects an already-expired replacement without changing the credential" do
      cluster = Factories.kubernetes_cluster
      K8sCluster::ClusterCredential.upsert!(cluster: cluster, kubeconfig: token_kubeconfig(token: "original"), user: admin)
      cluster.save!
      credential = K8sCluster::ClusterCredential.credential_for(cluster)

      patch "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}", params: {
        kubernetes_cluster: { kubeconfig: token_kubeconfig(token: jwt(1.minute.ago)) }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "message")).to include("already expired")
      expect(credential.reload.payload).to include("original")
    end

    it "re-parses a new kubeconfig on update, rotating credentials" do
      cluster = Factories.kubernetes_cluster
      cluster.token = "old-token"
      cluster.save!

      patch "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}", params: {
        kubernetes_cluster: { kubeconfig: token_kubeconfig(token: "new-token", server: "https://new.example.com:6443") }
      }

      expect(response).to have_http_status(:ok)
      cluster.reload
      expect(cluster.token).to be_nil
      expect(cluster.api_server_url).to eq("https://new.example.com:6443")
      expect(cluster.credential_kind).to eq("token")
      credential = CredentialStore::Credential.find(cluster.credential_store_credential_id)
      expect(credential.payload).to include("new-token")
      expect(credential.payload).not_to include("old-token")
    end

    it "rejects an invalid kubeconfig server on update without rotating credentials" do
      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "Prod", kubeconfig: token_kubeconfig(token: "old-token") }
      }
      cluster = KubernetesCluster.find(parse_body.dig("kubernetes_cluster", "id"))
      original_credential_id = cluster.credential_store_credential_id
      original_credential = CredentialStore::Credential.find(original_credential_id)

      patch "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}", params: {
        kubernetes_cluster: { kubeconfig: token_kubeconfig(token: "new-token", server: "/relative/path") }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(cluster.reload).to have_attributes(
        api_server_url: "https://k8s.example.com:6443",
        credential_store_credential_id: original_credential_id
      )
      expect(original_credential.reload.payload).to include("old-token")
      expect(original_credential.payload).not_to include("new-token")
    end

    it "rejects credential rotation when credential_store is disabled" do
      allow(CredentialStore).to receive(:enabled?).and_return(false)

      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "Prod", kubeconfig: token_kubeconfig(token: "hunter2") }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(KubernetesCluster.count).to eq(0)
      expect(CredentialStore::Credential.count).to eq(0)
    end

    it "deletes a cluster" do
      cluster = Factories.kubernetes_cluster

      delete "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}"

      expect(response).to have_http_status(:no_content)
      expect(KubernetesCluster.where(id: cluster.id)).not_to exist
    end

    describe "test_connection" do
      it "reports success for a draft kubeconfig without persisting anything" do
        allow(K8sCluster::ConnectionTester).to receive(:test_params).and_return({ success: true })

        expect {
          post "/api/v1/app/admin/kubernetes_clusters/test", params: {
            kubernetes_cluster: { kubeconfig: token_kubeconfig }
          }
        }.not_to change(KubernetesCluster, :count)

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(true)
      end

      it "reports a parse error for an unparsable draft kubeconfig" do
        post "/api/v1/app/admin/kubernetes_clusters/test", params: {
          kubernetes_cluster: { kubeconfig: "not: [valid" }
        }

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(false)
        expect(parse_body["error"]).to be_present
      end

      it "reports a parse error for a draft kubeconfig with an unsupported server scheme" do
        expect(K8sCluster::ConnectionTester).not_to receive(:test_params)

        post "/api/v1/app/admin/kubernetes_clusters/test", params: {
          kubernetes_cluster: { kubeconfig: token_kubeconfig(server: "ftp://k8s.example.com") }
        }

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(false)
        expect(parse_body["error"]).to match(/absolute HTTP\(S\) URL/)
      end

      it "tests an existing cluster using its stored credentials" do
        cluster = Factories.kubernetes_cluster
        cluster.token = "stored-token"
        cluster.save!
        allow(K8sCluster::ConnectionTester).to receive(:test).with(cluster, context: instance_of(McpToolContext)).and_return({ success: true })

        post "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/test"

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(true)
      end
    end
  end
end
