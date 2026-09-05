require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/kubernetes_clusters", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }

  def parse_body = JSON.parse(response.body)

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

    it "creates a cluster by parsing a pasted kubeconfig" do
      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "Prod", kubeconfig: token_kubeconfig(token: "hunter2") }
      }

      expect(response).to have_http_status(:created)
      expect(response.body).not_to include("hunter2")

      cluster = KubernetesCluster.find(parse_body.dig("kubernetes_cluster", "id"))
      expect(cluster.api_server_url).to eq("https://k8s.example.com:6443")
      expect(cluster.token).to eq("hunter2")
      expect(cluster.agentic_access_enabled).to be false
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

    it "rejects invalid params" do
      post "/api/v1/app/admin/kubernetes_clusters", params: {
        kubernetes_cluster: { label: "", kubeconfig: token_kubeconfig }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(KubernetesCluster.count).to eq(0)
    end

    it "updates a cluster's label without requiring a new kubeconfig" do
      cluster = Factories.kubernetes_cluster(label: "Old label")

      patch "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}", params: {
        kubernetes_cluster: { label: "Renamed" }
      }

      expect(response).to have_http_status(:ok)
      expect(cluster.reload.label).to eq("Renamed")
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
      expect(cluster.token).to eq("new-token")
      expect(cluster.api_server_url).to eq("https://new.example.com:6443")
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

      it "tests an existing cluster using its stored credentials" do
        cluster = Factories.kubernetes_cluster
        cluster.token = "stored-token"
        cluster.save!
        allow(K8sCluster::ConnectionTester).to receive(:test).with(cluster).and_return({ success: true })

        post "/api/v1/app/admin/kubernetes_clusters/#{cluster.id}/test"

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(true)
      end
    end
  end
end
