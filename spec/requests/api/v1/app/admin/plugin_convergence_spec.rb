require "rails_helper"

RSpec.describe "API: plugin convergence", type: :request do
  it "returns desired state and per-process convergence to an admin" do
    admin = Factories.user(admin: true)
    sign_in_as(admin)
    InstanceVersion.create!(hostname: "web-a", role: "web", version: "sha", started_at: 1.minute.ago,
      last_heartbeat_at: Time.current, plugin_set_revision: 0, plugin_set_details: { "plugins" => [] })

    get "/api/v1/app/admin/plugin_convergence"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include("desired_revision" => 0)
    expect(JSON.parse(response.body).fetch("processes").sole).to include("hostname" => "web-a", "state" => "converged")
  end
end
