require "rails_helper"

RSpec.describe "API: /api/v1/app/mobile_devices", type: :request do
  let(:user) { Factories.user(email_address: "op@example.com", password: "supersecret") }
  let(:token) { "cd" * 32 }

  before do
    user
    post "/api/v1/app/auth/session", params: { email_address: "op@example.com", password: "supersecret" }, as: :json
  end

  it "registers a device against the current session and is idempotent" do
    params = { token: token.upcase, bundle_id: "dev.syrus.app", apns_environment: "sandbox", device_name: "Phone" }
    expect { post "/api/v1/app/mobile_devices", params: params, as: :json }.to change(MobileDevice, :count).by(1)
    expect(response).to have_http_status(:created)
    device = MobileDevice.last
    expect(device.token).to eq(token)
    expect(device.user).to eq(user)
    expect(device.session).to eq(user.sessions.last)

    expect { post "/api/v1/app/mobile_devices", params: params, as: :json }.not_to change(MobileDevice, :count)
  end

  it "rejects invalid tokens and missing tokens" do
    post "/api/v1/app/mobile_devices", params: { token: "zzz", bundle_id: "dev.syrus.app" }, as: :json
    expect(response).to have_http_status(:unprocessable_content)
    post "/api/v1/app/mobile_devices", params: { bundle_id: "dev.syrus.app" }, as: :json
    expect(response).to have_http_status(:bad_request)
  end

  it "unregisters only the caller's own token" do
    MobileDevice.register!(user: user, session: nil, attributes: { token: token, bundle_id: "b" })
    other = MobileDevice.register!(user: Factories.user, session: nil, attributes: { token: "ef" * 32, bundle_id: "b" })

    delete "/api/v1/app/mobile_devices/unregister", params: { token: "ef" * 32 }, as: :json
    expect(other.reload).to be_present
    delete "/api/v1/app/mobile_devices/unregister", params: { token: token }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(MobileDevice.where(token: token)).to be_empty
  end

  it "requires authentication" do
    delete "/api/v1/app/auth/session"
    post "/api/v1/app/mobile_devices", params: { token: token, bundle_id: "b" }, as: :json
    expect(response).to have_http_status(:unauthorized)
  end
end
