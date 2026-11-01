require "rails_helper"
require Rails.root.join("db/migrate/20261101193036_reset_coworker_legacy_authority")

RSpec.describe ResetCoworkerLegacyAuthority do
  it "removes every legacy coworker grant without changing the coworker" do
    user = Factories.user
    repository = Factories.repository(user:)
    coworker = Coworkers::Coworker.create!(
      owner_user: user, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
    )
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")

    described_class.new.up

    expect(coworker.reload).to be_persisted
    expect(Coworkers::Grant).to be_none
  end
end
