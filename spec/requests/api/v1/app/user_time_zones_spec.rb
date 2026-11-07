require "rails_helper"

RSpec.describe "API: /api/v1/app/user_time_zone", type: :request do
  let(:user) { Factories.user(time_zone: "Etc/UTC", time_zone_mode: "automatic") }

  it "requires authentication" do
    patch "/api/v1/app/user_time_zone", params: { time_zone: "Europe/Berlin" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "updates an automatic zone from a validated browser report" do
    sign_in_as(user)

    patch "/api/v1/app/user_time_zone", params: { time_zone: "Europe/Berlin" }

    expect(response).to have_http_status(:ok)
    expect(user.reload).to have_attributes(time_zone: "Europe/Berlin", time_zone_mode: "automatic")
  end

  it "does not move a manual zone when the browser reports travel" do
    user.update!(time_zone: "America/New_York", time_zone_mode: "manual")
    sign_in_as(user)

    patch "/api/v1/app/user_time_zone", params: { time_zone: "Europe/Berlin" }

    expect(response).to have_http_status(:ok)
    expect(user.reload.time_zone).to eq("America/New_York")
  end

  it "supports a validated manual override" do
    sign_in_as(user)

    patch "/api/v1/app/user_time_zone", params: { time_zone: "Asia/Tokyo", mode: "manual" }

    expect(response).to have_http_status(:ok)
    expect(user.reload).to have_attributes(time_zone: "Asia/Tokyo", time_zone_mode: "manual")
  end

  it "rejects non-IANA zones" do
    sign_in_as(user)

    patch "/api/v1/app/user_time_zone", params: { time_zone: "Eastern Time (US & Canada)" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.time_zone).to eq("Etc/UTC")
  end
end
