require "rails_helper"

RSpec.describe "API: /api/v1/app/push_devices", type: :request do
  let(:user) { Factories.user }
  let(:other) { Factories.user }
  let(:token) { "ab" * 32 }

  it "401s when signed out" do
    post "/api/v1/app/push_devices", params: { token: token }

    expect(response).to have_http_status(:unauthorized)
  end

  it "registers a device for the signed-in user and session" do
    sign_in_as(user)

    post "/api/v1/app/push_devices", params: { token: token.upcase, environment: "sandbox", bundle_id: "dev.syrus.ios", device_name: "iPhone", app_version: "1.0 (1)" }

    expect(response).to have_http_status(:ok)
    device = PushDevice.find_by!(token: token)
    expect(device).to have_attributes(user: user, environment: "sandbox", bundle_id: "dev.syrus.ios", platform: "ios")
    expect(device.session).to be_a(Session)
    expect(JSON.parse(response.body).dig("push_device", "id")).to eq(device.id)
  end

  it "is idempotent and moves the token to the latest user" do
    sign_in_as(user)
    post "/api/v1/app/push_devices", params: { token: token }
    delete "/session"
    sign_in_as(other)
    post "/api/v1/app/push_devices", params: { token: token }

    expect(PushDevice.where(token: token).count).to eq(1)
    expect(PushDevice.find_by!(token: token).user).to eq(other)
  end

  it "registers via bearer token without a session" do
    user.generate_api_token!
    post "/api/v1/app/push_devices", params: { token: token }, headers: { "Authorization" => "Bearer #{user.api_token}" }

    expect(response).to have_http_status(:ok)
    expect(PushDevice.find_by!(token: token)).to have_attributes(user: user, session: nil)
  end

  it "rejects malformed tokens and requires a token" do
    sign_in_as(user)

    post "/api/v1/app/push_devices", params: { token: "not hex!" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body).dig("error", "code")).to eq("validation_failed")

    post "/api/v1/app/push_devices", params: {}
    expect(response).to have_http_status(:bad_request)
  end

  it "removes a device by id or token, only for its owner" do
    sign_in_as(user)
    mine = PushDevice.register!(user: user, token: token)
    theirs = PushDevice.register!(user: other, token: "cd" * 32)

    delete "/api/v1/app/push_devices/#{theirs.id}"
    expect(response).to have_http_status(:not_found)

    delete "/api/v1/app/push_devices/#{mine.id}"
    expect(response).to have_http_status(:no_content)
    expect(PushDevice.exists?(mine.id)).to be(false)

    again = PushDevice.register!(user: user, token: "ef" * 32)
    delete "/api/v1/app/push_devices/destroy_by_token", params: { token: again.token }
    expect(response).to have_http_status(:no_content)
    expect(PushDevice.exists?(again.id)).to be(false)
    expect(PushDevice.exists?(theirs.id)).to be(true)
  end
end
