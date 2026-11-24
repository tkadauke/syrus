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

  it "invalidates the device when the session signs out" do
    post "/api/v1/app/mobile_devices", params: { token: token, bundle_id: "b" }, as: :json
    expect(MobileDevice.where(token: token)).to exist
    delete "/api/v1/app/auth/session"
    expect(MobileDevice.where(token: token)).to be_empty
  end

  describe "diagnostics" do
    it "lists only the caller's devices with masked tokens" do
      post "/api/v1/app/mobile_devices", params: { token: token, bundle_id: "b", apns_environment: "sandbox", app_version: "1.2" }, as: :json
      MobileDevice.register!(user: Factories.user, session: nil, attributes: { token: "ef" * 32, bundle_id: "b" })

      get "/api/v1/app/mobile_devices", as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["mobile_devices"].size).to eq(1)
      device = body["mobile_devices"].first
      expect(device).to include("apns_environment" => "sandbox", "app_version" => "1.2", "token_suffix" => token.last(6))
      expect(response.body).not_to include(token)
      expect(body).to have_key("apns_configured")
    end
  end

  describe "test_notification" do
    let(:client) { instance_double(Apns::Client, configured?: true) }

    before do
      @original_client = MobileDevices::PushDelivery.client
      MobileDevices::PushDelivery.client = client
    end

    after { MobileDevices::PushDelivery.client = @original_client }

    def register(owner, hex)
      MobileDevice.register!(user: owner, session: nil, attributes: { token: hex, bundle_id: "dev.syrus.app" })
    end

    it "pushes a test payload with a deep link to the caller's devices only" do
      mine = register(user, token)
      theirs = register(Factories.user, "ef" * 32)
      allow(client).to receive(:deliver).and_return(Apns::Client::Result.new(status: 200))

      expect { post "/api/v1/app/mobile_devices/test_notification", as: :json }.not_to change(Notification, :count)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to include("delivered" => 1, "target_path" => "/notifications")
      expect(response.parsed_body["results"]).to eq([ { "mobile_device_id" => mine.id, "outcome" => "delivered", "status" => 200, "reason" => nil } ])
      expect(client).to have_received(:deliver).once.with(hash_including(device: mine, payload: hash_including(syrus: { kind: "test", target_path: "/notifications" })))
      expect(client).not_to have_received(:deliver).with(hash_including(device: theirs))
      expect(mine.reload.last_delivered_at).to be_present
    end

    it "can be narrowed to the calling installation's token" do
      register(user, token)
      other = register(user, "ab" * 32)
      allow(client).to receive(:deliver).and_return(Apns::Client::Result.new(status: 200))

      post "/api/v1/app/mobile_devices/test_notification", params: { token: "ab" * 32 }, as: :json

      expect(client).to have_received(:deliver).once.with(hash_including(device: other))
    end

    it "disables a rejected token and reports it" do
      device = register(user, token)
      allow(client).to receive(:deliver).and_return(Apns::Client::Result.new(status: 400, reason: "BadDeviceToken"))

      post "/api/v1/app/mobile_devices/test_notification", as: :json

      expect(response.parsed_body["delivered"]).to eq(0)
      expect(response.parsed_body["results"].first).to include("outcome" => "token_rejected", "reason" => "BadDeviceToken")
      expect(device.reload.disabled_reason).to eq("BadDeviceToken")
    end

    it "reports transport errors and non-fatal APNs failures per device" do
      register(user, token)
      register(user, "ab" * 32)
      allow(client).to receive(:deliver).and_invoke(
        ->(**) { raise Errno::ECONNRESET },
        ->(**) { Apns::Client::Result.new(status: 429, reason: "TooManyRequests") }
      )

      post "/api/v1/app/mobile_devices/test_notification", as: :json

      expect(response.parsed_body["results"].map { |r| r["outcome"] }).to eq(%w[error failed])
    end

    it "explains when APNs is not configured" do
      register(user, token)
      allow(client).to receive(:configured?).and_return(false)

      post "/api/v1/app/mobile_devices/test_notification", as: :json

      expect(response).to have_http_status(:service_unavailable)
      expect(response.parsed_body.dig("error", "code")).to eq("apns_not_configured")
    end

    it "explains when the user has no active device" do
      register(user, token).disable!("Unregistered")

      post "/api/v1/app/mobile_devices/test_notification", as: :json

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body.dig("error", "code")).to eq("no_registered_device")
    end

    it "requires authentication" do
      delete "/api/v1/app/auth/session"
      post "/api/v1/app/mobile_devices/test_notification", as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
