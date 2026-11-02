require "rails_helper"

RSpec.describe ApprovalNotificationDeliveryJob do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job_record(user:, repository:) }

  it "delivers due requests as one notification batch and records every member" do
    requests = 2.times.map do |index|
      ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, origin: job, subject: user,
        purpose: "Approval #{index}", deduplication_key: "delivery-#{index}", delivery_state: "queued",
        delivery_metadata: { "deliver_after" => 1.minute.ago.iso8601, "urgency" => "normal" })
    end

    expect { described_class.perform_now(requests.first.id) }.to change(Notification.where(kind: "approval_request"), :count).by(1)
    notification = Notification.order(:id).last
    expect(notification).to have_attributes(user:, target_path: "/permissions/inbox")
    expect(notification.body).to include("2 approval requests")
    requests.each do |request|
      expect(request.reload).to have_attributes(delivery_state: "delivered")
      expect(request.delivery_metadata).to include("notification_id" => notification.id, "batch_size" => 2)
    end
  end
end
