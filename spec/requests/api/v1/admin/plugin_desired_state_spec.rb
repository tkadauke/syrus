require "rails_helper"

RSpec.describe "API: plugin desired state", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:headers) { { "Authorization" => "Bearer #{admin.generate_api_token!}" } }

  before do
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    release = PluginRelease.create!(name: "weather", version: "1.0.0", content_digest: "a" * 64,
      source: "bundled", trust_label: "reviewed", size_bytes: 0, uploaded_by: admin)
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release, roles: [ "web" ])
  end

  it "requires an admin token" do
    get "/api/v1/admin/plugin_desired_state"
    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the desired set and revision" do
    get "/api/v1/admin/plugin_desired_state", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body).to include("revision" => 0)
    expect(body.fetch("plugins").sole).to include("name" => "weather", "version" => "1.0.0", "roles" => [ "web" ])
  end
end
