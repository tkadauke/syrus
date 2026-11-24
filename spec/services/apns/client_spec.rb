require "rails_helper"

RSpec.describe Apns::Client do
  let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:config) { Apns::Configuration.new(team_id: "TEAM123456", key_id: "KEY1234567", private_key_pem: key.to_pem, default_topic: "dev.syrus.app") }
  let(:calls) { [] }
  let(:responses) { [ [ 200, "", "abc" ] ] }
  let(:transport) do
    ->(**req) { calls << req; responses.shift || [ 200, "", nil ] }
  end
  let(:device) { MobileDevice.new(token: "ab" * 32, bundle_id: "dev.syrus.app", apns_environment: "sandbox") }

  it "posts to the sandbox host with a signed ES256 bearer token and topic" do
    result = described_class.new(configuration: config, transport: transport).deliver(device: device, payload: { aps: { alert: "hi" } }, collapse_id: "n-1")

    expect(result).to be_success
    req = calls.first
    expect(req[:url]).to eq("https://api.sandbox.push.apple.com/3/device/#{'ab' * 32}")
    expect(req[:headers]).to include("apns-topic" => "dev.syrus.app", "apns-push-type" => "alert", "apns-collapse-id" => "n-1")
    token = req[:headers]["authorization"].delete_prefix("bearer ")
    payload, header = JWT.decode(token, key, true, algorithm: "ES256")
    expect(payload["iss"]).to eq("TEAM123456")
    expect(header["kid"]).to eq("KEY1234567")
    expect(JSON.parse(req[:body])).to eq("aps" => { "alert" => "hi" })
  end

  it "reuses the provider token until it ages out" do
    now = Time.at(1_800_000_000)
    client = described_class.new(configuration: config, transport: transport, clock: -> { now })
    client.deliver(device: device, payload: {})
    client.deliver(device: device, payload: {})
    now += described_class::TOKEN_TTL + 1
    client.deliver(device: device, payload: {})

    tokens = calls.map { |c| c[:headers]["authorization"] }
    expect(tokens[0]).to eq(tokens[1])
    expect(tokens[2]).not_to eq(tokens[0])
  end

  it "parses failure reasons and flags dead tokens" do
    responses.replace([ [ 400, '{"reason":"BadDeviceToken"}', nil ], [ 500, '{"reason":"InternalServerError"}', nil ] ])
    client = described_class.new(configuration: config, transport: transport)

    bad = client.deliver(device: device, payload: {})
    expect(bad.reason).to eq("BadDeviceToken")
    expect(bad).to be_invalid_token
    expect(client.deliver(device: device, payload: {})).not_to be_invalid_token
  end

  it "reports unconfigured when credentials are missing" do
    expect(Apns::Configuration.new(team_id: nil, key_id: nil, private_key_pem: nil)).not_to be_configured
    expect(described_class.new(configuration: config, transport: transport)).to be_configured
  end

  it "reads configuration from the environment, unescaping newlines" do
    cfg = Apns::Configuration.from_env("SYRUS_APNS_TEAM_ID" => "T", "SYRUS_APNS_KEY_ID" => "K", "SYRUS_APNS_AUTH_KEY" => key.to_pem.gsub("\n", "\\n"))
    expect(cfg).to be_configured
    expect(cfg.private_key).to be_a(OpenSSL::PKey::EC)
    expect(cfg.host_for("production")).to eq("https://api.push.apple.com")
  end
end
