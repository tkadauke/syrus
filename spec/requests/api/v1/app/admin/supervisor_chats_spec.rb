require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/supervisor_chat", type: :request do
  let(:admin) { Factories.user(admin: true) }
  let(:non_admin) { Factories.user(admin: false) }

  def parse_body
    JSON.parse(response.body)
  end

  def set_supervisor_feature(enabled)
    Feature.find_or_create_by!(slug: "admin_supervisor_chat") do |feature|
      feature.category = "Operations"
      feature.name = "Admin supervisor chat"
    end.update!(enabled: enabled)
  end

  it "401s when signed out" do
    get "/api/v1/app/admin/supervisor_chat"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "404s with feature_disabled for admins when the flag is off" do
    set_supervisor_feature(false)
    sign_in_as(admin)

    get "/api/v1/app/admin/supervisor_chat"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("feature_disabled")
    expect(admin.chat_sessions.where(system_kind: "supervisor")).to be_empty
  end

  it "403s for non-admin users even when the flag is on" do
    admin
    set_supervisor_feature(true)
    sign_in_as(non_admin)

    get "/api/v1/app/admin/supervisor_chat"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "provisions and reopens one supervisor chat for an admin" do
    set_supervisor_feature(true)
    sign_in_as(admin)

    get "/api/v1/app/admin/supervisor_chat"

    expect(response).to have_http_status(:ok)
    first_body = parse_body
    first_chat = ChatSession.find(first_body.dig("chat", "id"))
    expect(first_body).to include(
      "message" => "Supervisor chat opened.",
      "redirect_to" => "/chats/#{first_chat.id}"
    )
    expect(first_body["chat"]).to include(
      "title" => "Supervisor",
      "system_kind" => "supervisor",
      "pinned" => true,
      "repository" => nil
    )

    get "/api/v1/app/admin/supervisor_chat"

    expect(response).to have_http_status(:ok)
    expect(parse_body.dig("chat", "id")).to eq(first_chat.id)
    expect(admin.chat_sessions.where(system_kind: "supervisor").count).to eq(1)
  end
end
