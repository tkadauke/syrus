require "rails_helper"
require Rails.root.join("plugins/coworkers/db/migrate/20261102192033_create_coworker_workspace_repositories")

RSpec.describe CreateCoworkerWorkspaceRepositories do
  it "backfills only registrations created during completed coworker provisioning" do
    owner = Factories.user
    reused = Factories.repository(user: owner, owner: "acme", name: "reused", created_at: 2.hours.ago)
    dedicated = Factories.repository(user: owner, owner: "acme", name: "dedicated", created_at: 30.minutes.ago)
    reused_coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Reused", handle: "reused", workspace_repo: reused.remote_url
    )
    dedicated_coworker = Coworkers::Coworker.create!(
      owner_user: owner, name: "Dedicated", handle: "dedicated", workspace_repo: dedicated.remote_url
    )
    attempt_attributes = {
      owner_user: owner, state: "completed", seeded_at: 40.minutes.ago,
      completed_at: 20.minutes.ago, created_at: 1.hour.ago
    }
    Coworkers::ProvisioningAttempt.create!(
      **attempt_attributes, coworker: reused_coworker, idempotency_key: "reused",
      remote_owner: reused.owner, remote_name: reused.name, handle: reused_coworker.handle,
      branch: "coworkers/#{reused_coworker.handle}"
    )
    Coworkers::ProvisioningAttempt.create!(
      **attempt_attributes, coworker: dedicated_coworker, idempotency_key: "dedicated",
      remote_owner: dedicated.owner, remote_name: dedicated.name, handle: dedicated_coworker.handle,
      branch: "coworkers/#{dedicated_coworker.handle}"
    )

    described_class.new.up

    expect(Coworkers::WorkspaceRepository.pluck(:repository_id)).to include(dedicated.id)
    expect(Coworkers::WorkspaceRepository.pluck(:repository_id)).not_to include(reused.id)
  end
end
