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

  # A grant's catalog name is not always the capability its rules are stored
  # under: update! resolves the grant through the tools it covers and writes
  # rows under those tools' capabilities. Grouping the rules back by their own
  # capability matched nothing, so a capability that really was granted
  # projected as "off" with no scope and every tool behind it refused. Built
  # from a stubbed catalog rather than a particular plugin's capability, so it
  # keeps holding whichever plugins happen to be enabled.
  it "projects a grant whose rules are stored under another capability" do
    permissions = described_class.new(coworker)
    descriptors = Coworkers::GrantCatalog.all
    renamed = Mcp::CoworkerToolCatalog.all.filter_map do |tool|
      next unless tool.capability == "syrus.read_jobs"

      tool.with(capability: "fleet.read")
    end
    expect(renamed).not_to be_empty, "expected the catalog to cover syrus.read_jobs"

    permissions.update!(capability: "syrus.read_jobs", approval_policy: "auto", actor: owner)
    allow(Mcp::CoworkerToolCatalog).to receive(:all).and_return(renamed)
    allow(Coworkers::GrantCatalog).to receive(:all)
      .and_return(descriptors.map { |entry| entry.name == "syrus.read_jobs" ? entry.with(name: "fleet.read") : entry })

    expect(described_class.new(coworker).entries).to include(
      include(capability: "fleet.read", approval_policy: "auto")
    )
  end

  it "revokes superseded rules instead of mutating or deleting their audit history" do
    permissions = described_class.new(coworker)
    permissions.update!(capability: "syrus.read_jobs", approval_policy: "auto", actor: owner)
    old_ids = permissions.rules.ids

    permissions.update!(capability: "syrus.read_jobs", approval_policy: "confirm", actor: owner)

    expect(PermissionRule.where(id: old_ids)).to all be_revoked_at
    expect(permissions.rules).to all have_attributes(policy: "ask")
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
