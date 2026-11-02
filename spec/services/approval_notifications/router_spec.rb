require "rails_helper"

RSpec.describe ApprovalNotifications::Router do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(approval_delivery_preferences: preferences) }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job_record(user:, repository:) }
  let(:request) do
    ChatPendingAction.create!(request_kind: "authorization_request", user:, repository:, origin: job, subject: user,
      purpose: "Restart the workload", deduplication_key: "approval-delivery")
  end
  let(:preferences) do
    { "enabled" => true, "batch_minutes" => 10, "quiet_hours_enabled" => false,
      "quiet_hours_start" => "22:00", "quiet_hours_end" => "07:00", "time_zone" => "UTC" }
  end

  before do
    request.authorization_items.create!(kind: "operation", capability: "k8s.workload", operation: "restart",
      operation_version: 1, invocation_fingerprint: "sha256:restart", resource_type: "cluster", resource_scope: {}, normalized_arguments: {}, effects: [ "operational" ], risk: "medium",
      policy_chain: [], decisive_rule: {}, requested_durations: [ "invocation" ])
  end

  it "batches normal requests while recording urgency on the durable request" do
    now = Time.zone.parse("2026-11-02 12:00:00")

    expect { described_class.route!(request, now:) }.to have_enqueued_job(ApprovalNotificationDeliveryJob).at(now + 10.minutes)
    expect(request.reload).to have_attributes(delivery_state: "queued")
    expect(request.delivery_metadata).to include("urgency" => "normal", "deliver_after" => (now + 10.minutes).iso8601)
  end

  it "holds urgent requests until quiet hours end without suppressing their request state" do
    user.update!(approval_delivery_preferences: preferences.merge("quiet_hours_enabled" => true))
    request.authorization_items.first.update!(risk: "high")
    now = Time.zone.parse("2026-11-02 23:30:00")

    expect { described_class.route!(request, now:) }.to have_enqueued_job(ApprovalNotificationDeliveryJob).at(Time.zone.parse("2026-11-03 07:00:00"))
    expect(request.reload).to be_pending
    expect(request.delivery_metadata).to include("urgency" => "urgent")
  end

  it "suppresses only external delivery when the preference is disabled" do
    user.update!(approval_delivery_preferences: preferences.merge("enabled" => false))

    expect { described_class.route!(request) }.not_to have_enqueued_job(ApprovalNotificationDeliveryJob)
    expect(request.reload).to have_attributes(state: "pending", delivery_state: "delivered")
    expect(request.delivery_metadata).to include("suppressed" => "preference")
  end
end
