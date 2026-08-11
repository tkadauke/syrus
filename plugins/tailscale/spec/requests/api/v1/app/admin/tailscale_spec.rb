require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/tailscale/status", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user(admin: false) }

  def parse_body = JSON.parse(response.body)

  before do
    PluginRecord.find_by!(name: "tailscale").update!(enabled: true)
    allow(Tailscale::DaemonManager.instance).to receive(:alive?).and_return(false)
  end

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/tailscale/status"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/tailscale/status"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns the tailscale status payload for app admins" do
    sign_in_as(admin)

    get "/api/v1/app/admin/tailscale/status"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "daemon_running" => false,
      "connected" => false,
      "hostname" => nil,
      "tailscale_url" => nil,
      "auth_key_present" => a_boolean,
      "net_admin_capable" => a_boolean
    )
  end

  it "404s when the Tailscale plugin is disabled" do
    PluginRecord.find_by!(name: "tailscale").update!(enabled: false)
    sign_in_as(admin)

    get "/api/v1/app/admin/tailscale/status"

    expect(response).to have_http_status(:not_found)
    expect(parse_body).to include("error" => "tailscale_plugin_disabled")
  end

  def a_boolean
    satisfy { |value| value == true || value == false }
  end
end
