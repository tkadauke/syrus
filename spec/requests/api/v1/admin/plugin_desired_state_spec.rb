require "rails_helper"

RSpec.describe "API: plugin desired state", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:auth) { { "Authorization" => "Bearer #{admin.generate_api_token!}" } }

  it "returns the current revision and external desired set to admins" do
    release = PluginRelease.create!(
      name: "mail", version: "3.1", content_digest: "b" * 64,
      source: "bundled", trust_label: "operator", size_bytes: 0
    )
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    installation = PluginInstallation.create!(
      plugin_name: "mail", plugin_release: release, enabled_for_sync: true,
      fleet_quarantined: true, roles: [ "worker" ]
    )
    PluginDesiredStateRevision.create!(revision: 7)

    get "/api/v1/admin/plugin_desired_state", headers: auth

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["revision"]).to eq(7)
    expect(body.fetch("plugins").sole).to include(
      "name" => "mail", "version" => "3.1", "enabled_for_sync" => true,
      "fleet_quarantined" => true, "roles" => [ "worker" ],
      "desired_since" => installation.desired_since.iso8601(3)
    )
  end

  it "rejects non-admin tokens" do
    admin
    user = Factories.user(admin: false)
    get "/api/v1/admin/plugin_desired_state", headers: { "Authorization" => "Bearer #{user.generate_api_token!}" }

    expect(response).to have_http_status(:forbidden)
  end
end
