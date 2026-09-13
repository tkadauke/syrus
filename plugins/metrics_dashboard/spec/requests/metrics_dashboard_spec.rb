require "rails_helper"

RSpec.describe "GET /api/v1/app/metrics_dashboard", type: :request do
  # `let!` because User promotes the very first account to admin, so a lazily
  # created member would silently be one.
  let!(:admin) { Factories.user(global_role: "admin") }
  let(:member) { Factories.user }

  def sign_in_as(user)
    post "/api/v1/app/auth/session", params: { email_address: user.email_address, password: "supersecret" }
  end

  context "when the plugin is enabled" do
    # The plugin route dispatcher consults the *registry* before the controller
    # runs, so stubbing MetricsDashboard.enabled? is not enough -- the manifest
    # has to actually report enabled.
    before { PluginRecord.find_or_create_by!(name: "metrics_dashboard").update!(enabled: true, disableable: true) }

    it "serves the dashboard payload to an admin" do
      sign_in_as(admin)

      get "/api/v1/app/metrics_dashboard"

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["panels"].map { |panel| panel["key"] })
        .to include("queue_oldest_age", "queue_ready", "feature_usage")
      expect(body["windows"]).to include("1h", "24h")
    end

    # Instance-wide operational numbers -- queue depth, failure counts, which
    # plugins are on -- are not scoped to the requesting user's own work.
    it "refuses a non-admin" do
      sign_in_as(member)

      get "/api/v1/app/metrics_dashboard"

      expect(response).to have_http_status(:forbidden)
    end
  end

  # A disabled plugin must not serve its API, or "disabled" means only that the
  # nav entry is hidden.
  it "answers plugin_disabled when the plugin is off" do
    PluginRecord.find_or_create_by!(name: "metrics_dashboard").update!(enabled: false, disableable: true)
    sign_in_as(admin)

    get "/api/v1/app/metrics_dashboard"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body.dig("error", "code")).to eq("plugin_disabled")
  end
end
