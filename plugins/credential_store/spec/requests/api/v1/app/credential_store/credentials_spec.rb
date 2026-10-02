require "rails_helper"

RSpec.describe "API: /api/v1/app/credential_store/credentials", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:operator) { Factories.user(admin: false, email_address: "operator@example.com") }
  let(:other_user) { Factories.user(admin: false, email_address: "other@example.com") }
  let(:repository) { Factories.repository(user: operator, owner: "acme", name: "widgets") }
  let(:team) do
    Team.create!(name: "Deployers").tap do |created|
      created.team_memberships.create!(user: operator, role: "owner")
    end
  end

  def parse_body = JSON.parse(response.body)

  def create_credential(**attrs)
    CredentialStore::Credential.create!({
      name: "Deploy token",
      credential_type: "credential_store.generic",
      scope_type: "user",
      scope_id: operator.id,
      created_by: admin,
      owner_user: operator,
      payload: "secret-token",
      safe_metadata: { "host" => "github.com", "username" => "deploy-bot" },
      target_constraints: { "allowed_hosts" => [ "github.com" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ "git.push" ],
      last_rotated_at: 1.hour.ago
    }.merge(attrs))
  end

  it "lists only visible credentials and never returns payload material" do
    visible = create_credential(scope_type: "user", scope_id: operator.id, payload: "visible-secret")
    hidden = create_credential(scope_type: "user", scope_id: other_user.id, owner_user: other_user, payload: "hidden-secret")
    CredentialStore::CredentialAccessEvent.record!(
      credential: visible,
      user: operator,
      surface: "workflow",
      action: "use",
      result: "allowed",
      purpose: "deploy"
    )

    sign_in_as(operator)
    get "/api/v1/app/credential_store/credentials"

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body.fetch("credentials").map { |credential| credential.fetch("id") }).to eq([ visible.id ])
    expect(body.dig("credentials", 0, "last_access")).to include(
      "action" => "use",
      "surface" => "workflow",
      "result" => "allowed"
    )
    expect(response.body).not_to include("visible-secret")
    expect(response.body).not_to include("hidden-secret")
    expect(body.dig("credentials", 0)).not_to have_key("payload")
    expect(hidden.reload.payload).to eq("hidden-secret")
  end

  it "does not return payload material from show" do
    credential = create_credential(payload: "show-secret")

    sign_in_as(operator)
    get "/api/v1/app/credential_store/credentials/#{credential.id}"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("credential", "id")).to eq(credential.id)
    expect(parse_body.fetch("credential")).not_to have_key("payload")
    expect(response.body).not_to include("show-secret")
  end

  it "authorizes user-scoped credentials to the referenced user or an admin" do
    sign_in_as(operator)

    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "user", scope_id: operator.id, payload: "mine")
    }
    expect(response).to have_http_status(:created)

    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "user", scope_id: other_user.id, payload: "theirs")
    }
    expect(response).to have_http_status(:forbidden)

    sign_in_as(admin)
    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "user", scope_id: other_user.id, payload: "admin-created")
    }
    expect(response).to have_http_status(:created)
  end

  it "authorizes repository-scoped credentials to repository admins" do
    reader = Factories.user(admin: false, email_address: "reader@example.com")
    repository.repository_memberships.create!(user: reader, role: "read")

    sign_in_as(reader)
    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "repository", scope_id: repository.id, payload: "reader-secret")
    }
    expect(response).to have_http_status(:forbidden)

    sign_in_as(operator)
    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "repository", scope_id: repository.id, payload: "repo-secret")
    }
    expect(response).to have_http_status(:created)
  end

  it "authorizes team-scoped credentials to team owners" do
    member = Factories.user(admin: false, email_address: "member@example.com")
    team.team_memberships.create!(user: member, role: "member")

    sign_in_as(member)
    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "team", scope_id: team.id, payload: "member-secret")
    }
    expect(response).to have_http_status(:forbidden)

    sign_in_as(operator)
    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "team", scope_id: team.id, payload: "team-secret")
    }
    expect(response).to have_http_status(:created)
  end

  it "authorizes instance-scoped credentials to global admins only" do
    sign_in_as(operator)
    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "instance", scope_id: nil, payload: "instance-secret")
    }
    expect(response).to have_http_status(:forbidden)

    sign_in_as(admin)
    post "/api/v1/app/credential_store/credentials", params: {
      credential: credential_params(scope_type: "instance", scope_id: nil, payload: "instance-secret")
    }
    expect(response).to have_http_status(:created)
  end

  it "rotates and revokes without displaying old or new payloads" do
    credential = create_credential(payload: "old-secret")

    sign_in_as(operator)
    post "/api/v1/app/credential_store/credentials/#{credential.id}/rotate", params: {
      credential: { payload: "new-secret" }
    }

    expect(response).to have_http_status(:ok)
    expect(credential.reload.payload).to eq("new-secret")
    expect(response.body).not_to include("old-secret")
    expect(response.body).not_to include("new-secret")

    post "/api/v1/app/credential_store/credentials/#{credential.id}/revoke"

    expect(response).to have_http_status(:ok)
    expect(credential.reload).to be_revoked
    expect(parse_body.fetch("credentials").find { |item| item.fetch("id") == credential.id }).to include("revoked_at")
  end

  it "does not allow an operator to move an editable credential into an unauthorized scope" do
    credential = create_credential(scope_type: "user", scope_id: operator.id)

    sign_in_as(operator)
    patch "/api/v1/app/credential_store/credentials/#{credential.id}", params: {
      credential: credential_params(scope_type: "instance", scope_id: nil, payload: "")
    }

    expect(response).to have_http_status(:forbidden)
    expect(credential.reload.scope_type).to eq("user")
  end

  it "exposes default and enabled plugin credential type names only" do
    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: false)
    sign_in_as(admin)

    get "/api/v1/app/credential_store/credentials"
    names = parse_body.dig("options", "credential_types").map { |entry| entry.fetch("name") }
    expect(names).to include("credential_store.generic")
    expect(names).not_to include("k8s_cluster.kubeconfig")

    PluginRecord.find_by!(name: "k8s_cluster").update!(enabled: true)
    get "/api/v1/app/credential_store/credentials"
    names = parse_body.dig("options", "credential_types").map { |entry| entry.fetch("name") }
    expect(names).to include("k8s_cluster.kubeconfig")
  end

  it "returns plugin_disabled when the credential store plugin is disabled" do
    PluginRecord.find_by!(name: "credential_store").update!(enabled: false)

    sign_in_as(admin)
    get "/api/v1/app/credential_store/credentials"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  ensure
    PluginRecord.find_by(name: "credential_store")&.update!(enabled: true)
  end

  def credential_params(scope_type:, scope_id:, payload:)
    {
      name: "Scoped credential",
      credential_type: "credential_store.generic",
      scope_type: scope_type,
      scope_id: scope_id,
      payload: payload,
      safe_metadata: { host: "github.com" },
      target_constraints: { allowed_hosts: [ "github.com" ] },
      allowed_surfaces: [ "workflow" ],
      allowed_tools: [ "git.push" ]
    }
  end
end
