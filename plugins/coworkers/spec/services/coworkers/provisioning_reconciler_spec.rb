require "rails_helper"

RSpec.describe Coworkers::ProvisioningReconciler do
  it "enqueues only recorded stale or cleanup-pending attempts" do
    owner = Factories.user
    stale = Coworkers::ProvisioningAttempt.create!(owner_user: owner, idempotency_key: "stale",
      remote_owner: "acme", remote_name: "homes", handle: "maya", branch: "coworkers/maya",
      expected_seeded_commit: "a" * 40, state: "provisioning", updated_at: 1.hour.ago)
    current = Coworkers::ProvisioningAttempt.create!(owner_user: owner, idempotency_key: "current",
      remote_owner: "acme", remote_name: "homes", handle: "ada", branch: "coworkers/ada", state: "provisioning")

    expect { described_class.call }.to have_enqueued_job(Coworkers::ProvisioningCleanupJob).with(stale.id).once
    expect(stale.reload.state).to eq("cleanup_pending")
    expect(current.reload.state).to eq("provisioning")
  end
end
