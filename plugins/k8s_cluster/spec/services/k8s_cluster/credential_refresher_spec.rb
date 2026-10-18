require "rails_helper"

RSpec.describe K8sCluster::CredentialRefresher do
  let(:admin) { Factories.user(admin: true) }
  let(:cluster) { Factories.kubernetes_cluster }
  let(:now) { Time.zone.parse("2026-10-17 12:00:00") }

  def jwt(expiry)
    [ { alg: "none" }, { exp: expiry.to_i }, "" ].map { |part| Base64.urlsafe_encode64(JSON.generate(part), padding: false) }.join(".")
  end

  def kubeconfig(id_token:, refresh_token: nil)
    YAML.dump(
      "current-context" => "default",
      "clusters" => [ { "name" => "cluster", "cluster" => { "server" => "https://k8s.example.com" } } ],
      "contexts" => [ { "name" => "default", "context" => { "cluster" => "cluster", "user" => "user" } } ],
      "users" => [ { "name" => "user", "user" => { "auth-provider" => { "name" => "oidc", "config" => {
        "id-token" => id_token, "refresh-token" => refresh_token, "client-id" => "syrus", "idp-issuer-url" => "https://idp.example.com"
      }.compact } } } ]
    )
  end

  def attach(payload, expires_at:)
    credential = CredentialStore::Credential.create!(
      name: "cluster-#{cluster.id}", credential_type: "k8s_cluster.kubeconfig", scope_type: "instance",
      created_by: admin, owner_user: admin, payload: payload, expires_at: expires_at,
      safe_metadata: {}, target_constraints: {}, allowed_surfaces: %w[admin], allowed_tools: %w[k8s_cluster_admin]
    )
    cluster.update!(credential_store_credential_id: credential.id)
    credential
  end

  def successful_response(body)
    Net::HTTPOK.new("1.1", "200", "OK").tap { |response| response.define_singleton_method(:body) { body } }
  end

  it "marks an expiring non-refreshable credential for operator rotation" do
    credential = attach(kubeconfig(id_token: jwt(now + 5.minutes)), expires_at: now + 5.minutes)

    expect(described_class.call(cluster, now: now)).to eq(:operator_action_required)
    expect(cluster.reload.credential_refresh_status).to eq("expiring")
    expect(cluster.credential_refresh_error).to include("Paste a replacement kubeconfig")
    expect(credential.reload.payload).to include("id-token")
  end

  it "records refresh failure without replacing encrypted material" do
    credential = attach(kubeconfig(id_token: jwt(now + 5.minutes), refresh_token: "refresh-secret"), expires_at: now + 5.minutes)
    http = class_double(Net::HTTP)
    allow(http).to receive(:get_response).and_return(instance_double(Net::HTTPBadGateway))

    expect(described_class.call(cluster, now: now, http: http)).to eq(:failed)
    expect(cluster.reload.credential_refresh_status).to eq("failed")
    expect(credential.reload.payload).to include("refresh-secret")
  end

  it "atomically stores refreshed OIDC material and recovers health" do
    credential = attach(kubeconfig(id_token: jwt(now + 5.minutes), refresh_token: "old-refresh"), expires_at: now + 5.minutes)
    refreshed_expiry = now + 1.hour
    discovery = successful_response(JSON.generate(token_endpoint: "https://idp.example.com/token"))
    refresh = successful_response(JSON.generate(id_token: jwt(refreshed_expiry), refresh_token: "new-refresh"))
    connection = instance_double(Net::HTTP, request: refresh)
    http = class_double(Net::HTTP)
    allow(http).to receive(:get_response).and_return(discovery)
    allow(http).to receive(:start).and_yield(connection)

    expect(described_class.call(cluster, now: now, http: http)).to eq(:refreshed)
    expect(credential.reload.expires_at).to eq(refreshed_expiry)
    expect(credential.payload).to include("new-refresh")
    expect(credential.payload).not_to include("old-refresh")
    expect(cluster.reload).to have_attributes(credential_refresh_status: "healthy", credential_refresh_error: nil)
  end

  it "serializes refresh attempts with the cluster row lock" do
    credential = attach(kubeconfig(id_token: jwt(now + 5.minutes)), expires_at: now + 5.minutes)
    expect(cluster).to receive(:with_lock).and_yield

    described_class.call(cluster, now: now)

    expect(credential.reload.expires_at).to eq(now + 5.minutes)
  end
end
