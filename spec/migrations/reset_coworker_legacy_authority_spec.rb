require "rails_helper"
require Rails.root.join("db/migrate/20261101193036_reset_coworker_legacy_authority")

RSpec.describe ResetCoworkerLegacyAuthority do
  it "idempotently translates legacy grants while preserving their audit rows" do
    user = Factories.user
    repository = Factories.repository(user:)
    coworker = Coworkers::Coworker.create!(
      owner_user: user, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
    )
    coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")

    described_class.new.up
    first_ids = PermissionRule.where(source: "coworker_grant_migration").ids
    described_class.new.up

    expect(coworker.reload).to be_persisted
    expect(coworker.grants.sole).to have_attributes(capability: "syrus.read_jobs", approval_policy: "auto")
    expect(PermissionRule.where(source: "coworker_grant_migration").ids).to eq(first_ids)
    expect(PermissionRule.where(id: first_ids)).to all have_attributes(
      subject_selector_type: "agent", subject_selector_id: coworker.id.to_s,
      policy: "allow", delegable: false
    )
    expect(PermissionRule.find(first_ids.first).provenance).to include(
      "legacy_coworker_grant_id" => coworker.grants.sole.id,
      "migration" => "Coworkers::LegacyGrantMigration"
    )
  end
end
