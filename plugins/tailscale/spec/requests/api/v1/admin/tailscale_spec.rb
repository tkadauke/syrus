require "rails_helper"

RSpec.describe "API: /api/v1/admin/tailscale/status", type: :request do
  let!(:admin) { Factories.user }
  let!(:admin_token) { admin.generate_api_token! }

  def auth = { "Authorization" => "Bearer #{admin_token}" }
  def parse_body = JSON.parse(response.body)

  before do
    PluginRecord.find_or_create_by!(name: "plugin_runtime").update!(enabled: true)
    PluginRecord.find_by!(name: "tailscale").update!(enabled: true)
    allow(PluginRuntime::Services).to receive(:endpoint_for).with("tailscale").and_return(nil)
  end

  it "401s without a token" do
    get "/api/v1/admin/tailscale/status"

    expect(response).to have_http_status(:unauthorized)
  end

  it "returns the tailscale status payload for admin API clients" do
    get "/api/v1/admin/tailscale/status", headers: auth

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["daemon_running"]).to eq(false)
    expect(body["connected"]).to eq(false)
    expect(body["hostname"]).to be_nil
    expect(body["tailscale_url"]).to be_nil
    expect(body).to have_key("auth_key_present")
  end

  it "404s when the Tailscale plugin is disabled" do
    PluginRecord.find_by!(name: "tailscale").update!(enabled: false)

    get "/api/v1/admin/tailscale/status", headers: auth

    expect(response).to have_http_status(:not_found)
    expect(parse_body).to include("error" => "tailscale_plugin_disabled")
  end
end
