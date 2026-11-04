require "rails_helper"

RSpec.describe Coworkers::LegacyGrantMigration do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-migrate",
      workspace_repo: "https://github.com/acme/workspace.git")
  end

  it "preserves queue provenance and constraints across retries" do
    grant = coworker.grants.create!(capability: "workspace.files", approval_policy: "queue",
      constraints: { "confirm_paths" => [ "SOUL.md" ] })

    first = described_class.call
    ids = PermissionRule.where(source: "coworker_grant_migration").ids
    second = described_class.call

    expect(first.to_h).to include(migrated: 1, conflicts: [], parity_errors: [], errors: [])
    expect(second.to_h).to include(migrated: 0, already_migrated: 1, conflicts: [], parity_errors: [], errors: [])
    expect(PermissionRule.where(source: "coworker_grant_migration").ids).to eq(ids)
    expect(coworker.permission_rules.entries).to include(include(
      capability: grant.capability, approval_policy: "queue", constraints: { "confirm_paths" => [ "SOUL.md" ] }
    ))
  end

  it "reports a conflict without replacing newer canonical rules" do
    grant = coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")
    coworker.permission_rules.update!(capability: grant.capability, approval_policy: "confirm", actor: owner)
    existing_ids = coworker.permission_rules.rules.ids

    result = described_class.call

    expect(result.migrated).to eq(0)
    matching_ids = existing_ids.select do |id|
      PermissionRule.find(id).capability.sub(/@v\d+\z/, "") == grant.capability
    end
    expect(result.conflicts).to contain_exactly(include(grant_id: grant.id, canonical_rule_ids: matching_ids))
    expect(coworker.permission_rules.rules.ids).to eq(existing_ids)
  end

  it "records off as an idempotency marker without revoking a later owner rule" do
    grant = coworker.grants.create!(capability: "workspace.files", approval_policy: "confirm")
    grant.update_column(:approval_policy, "off")

    first = described_class.call
    marker = PermissionRule.find_by!(source: "coworker_grant_migration")
    expect(marker).to have_attributes(policy: "deny")
    expect(first.parity_errors).to be_empty

    coworker.permission_rules.update!(capability: grant.capability, approval_policy: "auto", actor: owner)
    owner_rule_ids = coworker.permission_rules.rules.ids
    second = described_class.call

    expect(second.already_migrated).to eq(1)
    expect(coworker.permission_rules.rules.ids).to eq(owner_rule_ids)
  end

  it "recognizes equivalent canonical authority without replacing it" do
    grant = coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "confirm")
    coworker.permission_rules.update!(capability: grant.capability, approval_policy: "confirm", actor: owner)
    existing_ids = coworker.permission_rules.rules.ids

    result = described_class.call

    expect(result).to have_attributes(migrated: 0, already_canonical: 1, conflicts: [])
    expect(coworker.permission_rules.rules.ids).to eq(existing_ids)
  end

  it "records one bad row and continues translating later grants" do
    bad = coworker.grants.create!(capability: "syrus.read_jobs", approval_policy: "auto")
    bad.update_column(:capability, "missing.capability")
    other = Coworkers::Coworker.create!(owner_user: owner, name: "Ada", handle: "ada-migrate",
      workspace_repo: "https://github.com/acme/workspace.git")
    good = other.grants.create!(capability: "workspace.files", approval_policy: "auto")

    result = described_class.call

    expect(result.errors).to contain_exactly(include(grant_id: bad.id, error: /missing.capability/))
    expect(result.migrated).to eq(1)
    expect(PermissionRule.where(source: "coworker_grant_migration").pluck(:provenance)).to include(
      include("legacy_coworker_grant_id" => good.id)
    )
  end
end
