require "rails_helper"

RSpec.describe Push::NotificationDelivery do
  let(:user) { Factories.user }
  let(:notification) { Notification.create!(user: user, kind: "job_failed", body: "It broke") }
  let(:client) { instance_double(Push::ApnsClient, configured?: true) }

  before do
    PushDevice.create!(user: user, token: "ab" * 32, last_registered_at: Time.current)
  end

  it "delivers to active devices" do
    allow(client).to receive(:deliver).and_return(Push::ApnsClient::Response.new(status: 200, body: ""))
    expect(described_class.new(notification, client: client).deliver).to eq(1)
  end

  it "disables devices APNs reports as unregistered" do
    allow(client).to receive(:deliver).and_return(Push::ApnsClient::Response.new(status: 410, body: '{"reason":"Unregistered"}'))
    described_class.new(notification, client: client).deliver
    expect(PushDevice.active.count).to eq(0)
  end

  it "does nothing when APNs is not configured" do
    allow(client).to receive(:configured?).and_return(false)
    expect(client).not_to receive(:deliver)
    expect(described_class.new(notification, client: client).deliver).to eq(0)
  end

  it "survives transport errors" do
    allow(client).to receive(:deliver).and_raise("boom")
    expect(described_class.new(notification, client: client).deliver).to eq(0)
  end
end

RSpec.describe NotificationService, "push hook" do
  it "enqueues a push job for created notifications" do
    user = Factories.user
    expect {
      described_class.create_for(user: user, kind: "job_failed", body: "x")
    }.to have_enqueued_job(NotificationPushJob)
  end
end
