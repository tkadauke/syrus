require "rails_helper"

RSpec.describe Coworkers::PermissionRules do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url)
  end

  it "writes exact-agent canonical rules and projects them for the coworker editor" do
    described_class.new(coworker).update!(
      capability: "syrus.read_jobs", approval_policy: "auto", actor: owner,
      provenance: { "test" => true }
    )

    rules = PermissionRule.where(owner_user: owner, subject_selector_type: "agent", subject_selector_id: coworker.id.to_s)
    expect(rules).not_to be_empty
    expect(rules).to all have_attributes(policy: "allow", source: "coworker_permission", delegable: false)
    matching = rules.select { |rule| rule.capability.start_with?("syrus.read_jobs@v") }
    expect(matching).not_to be_empty
    expect(described_class.new(coworker).entries).to include(
      include(capability: "syrus.read_jobs", approval_policy: "auto")
    )
    expect(coworker.grants).to be_empty
  end

  it "revokes superseded rules instead of mutating or deleting their audit history" do
    permissions = described_class.new(coworker)
    permissions.update!(capability: "syrus.read_jobs", approval_policy: "auto", actor: owner)
    old_ids = permissions.rules.ids

    permissions.update!(capability: "syrus.read_jobs", approval_policy: "confirm", actor: owner)

    expect(PermissionRule.where(id: old_ids)).to all be_revoked_at
    expect(permissions.rules).to all have_attributes(policy: "ask", delegable: true)
    expect(PermissionRuleAuditEvent.where(permission_rule_id: old_ids, event_type: "revoked").count).to eq(old_ids.length)
  end

  it "preserves compatibility scopes when canonical descriptors have no resource scope" do
    scope = [ repository.id ]

    described_class.new(coworker).update!(
      capability: "code.read", approval_policy: "auto", scope:, actor: owner
    )

    expect(described_class.new(coworker).entries).to include(
      include(capability: "code.read", approval_policy: "auto", scope: scope)
    )
    expect(described_class.new(coworker).rules.map { |rule| rule.provenance["coworker_scope"] }).to all(eq(scope))
  end
end
