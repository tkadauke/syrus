require "rails_helper"

RSpec.describe "Credential Store CLI commands", type: :request do
  let!(:user) { Factories.user(admin: false) }

  before do
    PluginRecord.find_by!(name: "credential_store").update!(enabled: true)
    sign_in_as(user)
  end

  def execute(path, flags: {})
    post "/api/v1/app/cli_commands/execute", params: { plugin: "credential_store", path: path, args: [], flags: flags }, as: :json
  end

  it "lists declared credential types in table and JSON shapes" do
    execute(%w[credential types])
    expect(response).to have_http_status(:ok), response.body
    expect(response.parsed_body.dig("result", "columns")).to eq([ "NAME", "LABEL", "PLUGIN", "DESCRIPTION" ])

    execute(%w[credential types], flags: { json: true })
    types = JSON.parse(response.parsed_body.dig("result", "text"))
    expect(types).to include(include("name" => "token", "plugin" => "credential_store"))
  end

  it "uses management visibility and never returns encrypted payload material" do
    credential = CredentialStore::Credential.create!(
      name: "deploy-token", credential_type: "token", scope_type: "user", scope_id: user.id,
      owner_user: user, created_by: user, payload: "super-secret-value", safe_metadata: {},
      target_constraints: {}, allowed_surfaces: [ "workflow" ], allowed_tools: [], last_rotated_at: Time.current
    )
    execute(%w[credential credentials], flags: { json: true, type: "token" })

    expect(response).to have_http_status(:ok)
    payload = response.parsed_body.dig("result", "text")
    rows = JSON.parse(payload)
    expect(rows.pluck("id")).to include(credential.id)
    expect(payload).not_to include("super-secret-value", "payload")
    expect(response.body).not_to include("super-secret-value")
  end
end
