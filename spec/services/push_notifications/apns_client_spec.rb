require "rails_helper"

RSpec.describe PushNotifications::ApnsClient do
  let(:key) { OpenSSL::PKey::EC.generate("prime256v1") }
  let(:config) { PushNotifications::ApnsConfig.new(key_id: "KEY1234567", team_id: "TEAM123456", bundle_id: "dev.syrus.ios", private_key_pem: key.to_pem) }
  let(:transport) { double("transport") }
  let(:client) { described_class.new(config: config, transport: transport) }

  it "posts to the environment host with a signed ES256 provider token" do
    captured = nil
    allow(transport).to receive(:post) do |url, headers:, body:|
      captured = { url: url, headers: headers, body: body }
      described_class::Response.new(status: 200, body: "")
    end

    result = client.deliver(device_token: "ab" * 32, environment: "sandbox", payload: { aps: { alert: "hi" } }, collapse_id: "n-1")

    expect(result).to be_success
    expect(captured[:url]).to eq("https://api.sandbox.push.apple.com/3/device/#{'ab' * 32}")
    expect(captured[:headers]).to include("apns-topic" => "dev.syrus.ios", "apns-push-type" => "alert", "apns-collapse-id" => "n-1")
    jwt = captured[:headers]["authorization"].delete_prefix("bearer ")
    claims, header = JWT.decode(jwt, key, true, algorithm: "ES256")
    expect(claims["iss"]).to eq("TEAM123456")
    expect(header["kid"]).to eq("KEY1234567")
    expect(JSON.parse(captured[:body])).to eq("aps" => { "alert" => "hi" })
  end

  it "uses the production host by default and reuses the provider token" do
    tokens = []
    urls = []
    allow(transport).to receive(:post) do |url, headers:, **|
      urls << url
      tokens << headers["authorization"]
      described_class::Response.new(status: 200, body: "")
    end
    2.times { client.deliver(device_token: "ab" * 32, environment: "production", payload: {}) }

    expect(urls.uniq).to eq([ "https://api.push.apple.com/3/device/#{'ab' * 32}" ])
    expect(tokens.uniq.size).to eq(1)
  end

  it "classifies APNs rejections" do
    allow(transport).to receive(:post).and_return(described_class::Response.new(status: 400, body: '{"reason":"BadDeviceToken"}'))
    result = client.deliver(device_token: "ab" * 32, environment: "production", payload: {})
    expect(result).to be_unregistered
    expect(result.reason).to eq("BadDeviceToken")

    allow(transport).to receive(:post).and_return(described_class::Response.new(status: 429, body: '{"reason":"TooManyRequests"}'))
    expect(client.deliver(device_token: "ab" * 32, environment: "production", payload: {})).to be_retryable
  end

  it "treats transport errors as retryable" do
    allow(transport).to receive(:post).and_raise(Errno::ECONNRESET)
    result = client.deliver(device_token: "ab" * 32, environment: "production", payload: {})
    expect(result).to be_retryable
    expect(result).not_to be_success
  end
end
