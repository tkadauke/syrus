require "rails_helper"

RSpec.describe "API: /api/v1/app/push_devices", type: :request do
  let!(:user) { Factories.user(email_address: "push@example.com", api_token: "syrus_push_token") }
  let(:auth) { { "Authorization" => "Bearer syrus_push_token" } }
  let(:token) { "ab" * 32 }

  it "registers a device and is idempotent for the same token" do
    post "/api/v1/app/push_devices", params: { token: token, environment: "sandbox", bundle_id: "estate.syrus.app" }, headers: auth
    expect(response).to have_http_status(:ok)
    post "/api/v1/app/push_devices", params: { token: token.upcase, environment: "sandbox" }, headers: auth

    expect(user.push_devices.count).to eq(1)
    expect(user.push_devices.first.environment).to eq("sandbox")
  end

  it "reassigns a token to the most recent user and re-enables it" do
    other = Factories.user(email_address: "other@example.com")
    PushDevice.create!(user: other, token: token, last_registered_at: 1.day.ago, disabled_at: Time.current)

    post "/api/v1/app/push_devices", params: { token: token }, headers: auth

    device = PushDevice.find_by!(token: token)
    expect(device.user).to eq(user)
    expect(device.disabled_at).to be_nil
  end

  it "rejects malformed tokens" do
    post "/api/v1/app/push_devices", params: { token: "not-hex!" }, headers: auth
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "removes only the caller's token, idempotently" do
    other = Factories.user(email_address: "other2@example.com")
    PushDevice.create!(user: user, token: token, last_registered_at: Time.current)
    PushDevice.create!(user: other, token: "cd" * 32, last_registered_at: Time.current)

    delete "/api/v1/app/push_devices", params: { token: token }, headers: auth
    delete "/api/v1/app/push_devices", params: { token: "cd" * 32 }, headers: auth

    expect(response).to have_http_status(:no_content)
    expect(PushDevice.pluck(:token)).to eq([ "cd" * 32 ])
  end

  it "requires authentication" do
    post "/api/v1/app/push_devices", params: { token: token }
    expect(response).not_to have_http_status(:ok)
  end
end
