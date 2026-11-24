require "rails_helper"

RSpec.describe MobileDevices::PushDelivery do
  let(:user) { Factories.user }
  let(:notification) { NotificationService.create_for(user: user, kind: "job_failed", body: "Job failed", target_path: "/jobs/1") }
  let(:client) { instance_double(Apns::Client, configured?: true) }

  def register(token)
    MobileDevice.register!(user: user, session: nil, attributes: { token: token, bundle_id: "dev.syrus.app" })
  end

  it "sends to active devices, disables dead tokens and keeps others" do
    good = register("aa" * 32)
    dead = register("bb" * 32)
    allow(client).to receive(:deliver) do |device:, **|
      device == dead ? Apns::Client::Result.new(status: 410, reason: "Unregistered") : Apns::Client::Result.new(status: 200)
    end

    expect(described_class.new(notification, client: client).call).to eq(1)
    expect(dead.reload.disabled_at).to be_present
    expect(good.reload.last_delivered_at).to be_present
    expect(client).to have_received(:deliver).twice.with(hash_including(payload: hash_including(aps: hash_including(badge: 1, alert: hash_including(body: "Job failed")), syrus: hash_including(target_path: "/jobs/1", kind: "job_failed"))))
  end

  it "does nothing when APNs is not configured" do
    register("aa" * 32)
    allow(client).to receive(:configured?).and_return(false)
    expect(client).not_to receive(:deliver)
    expect(described_class.new(notification, client: client).call).to eq(0)
  end

  it "survives transport errors on one device" do
    register("aa" * 32)
    allow(client).to receive(:deliver).and_raise(Errno::ECONNRESET)
    expect(described_class.new(notification, client: client).call).to eq(0)
  end

  it "is enqueued by NotificationService only for users with active devices" do
    expect { NotificationService.create_for(user: user, kind: "job_failed", body: "x") }.not_to have_enqueued_job(MobilePushDeliveryJob)
    register("aa" * 32)
    expect { NotificationService.create_for(user: user, kind: "job_implemented", body: "y") }.to have_enqueued_job(MobilePushDeliveryJob)
  end
end
