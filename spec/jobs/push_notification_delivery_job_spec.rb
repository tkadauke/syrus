require "rails_helper"

RSpec.describe PushNotificationDeliveryJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:env) { { "SYRUS_APNS_KEY_ID" => "K", "SYRUS_APNS_TEAM_ID" => "T", "SYRUS_APNS_BUNDLE_ID" => "b", "SYRUS_APNS_PRIVATE_KEY" => "pem" } }

  it "is queued on a consumed queue" do
    expect(described_class.new.queue_name).to eq("control_plane")
  end

  it "enqueues from NotificationService only with credentials and an active device" do
    PushDevice.register!(user: user, token: "ab" * 32)

    expect { NotificationService.create_for(user: user, kind: "job_failed", body: "x") }
      .not_to have_enqueued_job(described_class)

    stub_const("ENV", ENV.to_h.merge(env))
    expect { NotificationService.create_for(user: user, kind: "job_failed", body: "y") }
      .to have_enqueued_job(described_class)
  end

  it "does not enqueue without a registered device" do
    stub_const("ENV", ENV.to_h.merge(env))
    expect { NotificationService.create_for(user: user, kind: "job_failed", body: "z") }
      .not_to have_enqueued_job(described_class)
  end

  it "delivers through the deliverer" do
    notification = Notification.create!(user: user, kind: "job_failed", body: "x")
    deliverer = instance_double(PushNotifications::Deliverer, deliver: 1)
    allow(PushNotifications::Deliverer).to receive(:new).and_return(deliverer)

    described_class.perform_now(notification.id)
    expect(deliverer).to have_received(:deliver).with(notification)
    expect { described_class.perform_now(0) }.not_to raise_error
  end
end
