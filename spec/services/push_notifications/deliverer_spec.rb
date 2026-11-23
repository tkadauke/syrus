require "rails_helper"

RSpec.describe PushNotifications::Deliverer do
  let(:user) { Factories.user }
  let(:config) { PushNotifications::ApnsConfig.new(key_id: "K", team_id: "T", bundle_id: "dev.syrus.ios", private_key_pem: "pem") }
  let(:client) { instance_double(PushNotifications::ApnsClient) }
  let(:notification) { Notification.create!(user: user, kind: "job_failed", body: "Build failed", target_path: "/jobs/5") }
  let!(:device) { PushDevice.register!(user: user, token: "ab" * 32, environment: "sandbox") }

  def result(status, reason = nil) = PushNotifications::ApnsClient::Result.new(status: status, reason: reason)

  it "does nothing when APNs is not configured" do
    unconfigured = PushNotifications::ApnsConfig.new(key_id: "", team_id: "", bundle_id: "", private_key_pem: "")
    expect(client).not_to receive(:deliver)
    expect(described_class.new(client: client, config: unconfigured).deliver(notification)).to eq(0)
  end

  it "delivers the payload to active devices" do
    expect(client).to receive(:deliver).with(
      hash_including(device_token: device.token, environment: "sandbox", payload: hash_including(aps: hash_including(badge: 1)))
    ).and_return(result(200))

    expect(described_class.new(client: client, config: config).deliver(notification)).to eq(1)
    expect(device.reload.last_delivered_at).to be_present
  end

  it "puts routing data in the payload" do
    payload = described_class.new(client: client, config: config).payload_for(notification, unread_count: 2)
    expect(payload[:syrus]).to include(notification_id: notification.id, kind: "job_failed", path: "/jobs/5")
    expect(payload[:aps][:alert][:body]).to eq("Build failed")
  end

  it "disables devices APNs reports as unregistered" do
    allow(client).to receive(:deliver).and_return(result(410, "Unregistered"))
    described_class.new(client: client, config: config).deliver(notification)
    expect(device.reload).not_to be_active
    expect(device.disabled_reason).to eq("Unregistered")
  end

  it "raises for retryable failures" do
    allow(client).to receive(:deliver).and_return(result(503, "ServiceUnavailable"))
    expect { described_class.new(client: client, config: config).deliver(notification) }
      .to raise_error(described_class::RetryableDeliveryError)
    expect(device.reload).to be_active
  end
end
