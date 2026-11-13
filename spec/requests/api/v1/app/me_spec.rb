require "rails_helper"

RSpec.describe "API: /api/v1/app/me", type: :request do
  it "returns only the current user and shell counts" do
    user = Factories.user(email_address: "operator@example.com")
    Factories.user(email_address: "teammate@example.com")
    sign_in_as(user)

    get "/api/v1/app/me"

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to match(
      "v" => 1,
      "current_user" => hash_including("email_address" => "operator@example.com"),
      "team_user_count" => 2,
      "unread_notifications_count" => 0
    )
  end

  it "requires authentication" do
    get "/api/v1/app/me"

    expect(response).to have_http_status(:unauthorized)
  end
end
