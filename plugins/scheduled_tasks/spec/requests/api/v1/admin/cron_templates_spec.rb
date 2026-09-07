require "rails_helper"

RSpec.describe "API: /api/v1/admin/cron_templates", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) { admin; Factories.user }
  let(:admin_token) { admin.generate_api_token! }
  let(:non_admin_token) { non_admin.generate_api_token! }

  def auth(token) = { "Authorization" => "Bearer #{token}" }
  def parse_body = JSON.parse(response.body)

  it "401s without an Authorization header" do
    get "/api/v1/admin/cron_templates"
    expect(response).to have_http_status(:unauthorized)
  end

  it "403s for a non-admin token" do
    get "/api/v1/admin/cron_templates", headers: auth(non_admin_token)
    expect(response).to have_http_status(:forbidden)
  end

  it "answers plugin_disabled with the plugin disabled" do
    PluginRecord.find_by!(name: "scheduled_tasks").update!(enabled: false)

    get "/api/v1/admin/cron_templates", headers: auth(admin_token)

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "lists templates instance-wide and filters by user" do
    other_user = Factories.user
    mine = Factories.cron_template(user: admin, name: "Mine")
    theirs = Factories.cron_template(user: other_user, name: "Theirs")

    get "/api/v1/admin/cron_templates", headers: auth(admin_token)
    expect(response).to have_http_status(:ok)
    expect(parse_body["cron_templates"].map { |t| t["id"] }).to contain_exactly(mine.id, theirs.id)

    get "/api/v1/admin/cron_templates", params: { user: other_user.email_address }, headers: auth(admin_token)
    expect(parse_body["cron_templates"].map { |t| t["id"] }).to contain_exactly(theirs.id)
  end

  it "returns template detail including the prompt" do
    template = Factories.cron_template(user: admin)

    get "/api/v1/admin/cron_templates/#{template.id}", headers: auth(admin_token)

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "id" => template.id,
      "prompt" => template.prompt,
      "cron_expression" => template.cron_expression
    )
  end
end
