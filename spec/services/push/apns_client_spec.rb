require "rails_helper"

RSpec.describe Push::ApnsClient do
  let(:pem) { OpenSSL::PKey::EC.generate("prime256v1").to_pem }
  let(:config) { Push::ApnsConfig.new("APNS_KEY_ID" => "KEY1234567", "APNS_TEAM_ID" => "TEAM123456", "APNS_PRIVATE_KEY" => pem) }
  let(:calls) { [] }
  let(:transport) { ->(**kw) { calls << kw; Push::ApnsClient::Response.new(status: 200, body: "") } }
  let(:device) { PushDevice.new(token: "ab" * 32, environment: "sandbox") }

  it "posts a token-authenticated request to the sandbox host" do
    client = described_class.new(config: config, transport: transport)
    client.deliver(device: device, alert: { "title" => "t", "body" => "b" }, payload: { notification_id: 1 })

    call = calls.first
    expect(call[:url]).to eq("https://api.sandbox.push.apple.com/3/device/#{device.token}")
    expect(call[:headers]["apns-topic"]).to eq("estate.syrus.app")
    jwt = call[:headers]["authorization"].delete_prefix("bearer ")
    header = JWT.decode(jwt, nil, false).last
    expect(header).to include("alg" => "ES256", "kid" => "KEY1234567")
    expect(JSON.parse(call[:body])).to include("notification_id" => 1, "aps" => hash_including("alert"))
  end

  it "reuses the provider token until it ages out" do
    now = Time.at(1_800_000_000)
    client = described_class.new(config: config, transport: transport, clock: -> { now })
    first = client.provider_token
    now += 10.minutes
    expect(client.provider_token).to eq(first)
    now += 40.minutes
    expect(client.provider_token).not_to eq(first)
  end

  it "classifies dead-token responses" do
    expect(Push::ApnsClient::Response.new(status: 410, body: "").invalid_token?).to be(true)
    expect(Push::ApnsClient::Response.new(status: 400, body: '{"reason":"BadDeviceToken"}').invalid_token?).to be(true)
    expect(Push::ApnsClient::Response.new(status: 429, body: '{"reason":"TooManyRequests"}').invalid_token?).to be(false)
  end

  it "reports unconfigured when credentials are missing" do
    expect(described_class.new(config: Push::ApnsConfig.new({})).configured?).to be(false)
  end
end
