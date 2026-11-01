require "rails_helper"

RSpec.describe PermissionRule do
  let(:owner) { Factories.user }
  let(:creator) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  def rule_attributes
    {
      owner_user: owner,
      subject_selector_type: "workflow_role",
      subject_selector_id: "implementer",
      subject_role_keys: [],
      subject_repository: repository,
      capability: "syrus.jobs@v1",
      operation: "syrus.jobs/cancel@v1",
      resource_type: "repository",
      resource_scope: { "repository_id" => repository.id },
      policy: "ask",
      constraints: { "maximum_jobs" => 1 },
      policy_layer: "repository",
      source: "operator",
      provenance: { "surface" => "permissions_hub" },
      created_by_user: owner,
      updated_by_user: owner
    }
  end

  def create_rule(**attributes)
    described_class.create!(rule_attributes.merge(attributes))
  end

  it "keeps active current-state rules efficiently queryable" do
    wildcard = create_rule(operation: nil)
    exact = create_rule(operation: "syrus.jobs/cancel@v1")
    create_rule(capability: "syrus.epics@v1")

    expect(described_class.active.for_owner(owner).for_capability("syrus.jobs@v1", "syrus.jobs/cancel@v1"))
      .to contain_exactly(wildcard, exact)
  end

  it "records immutable snapshots for creation, revision, and revocation" do
    rule = create_rule(created_by_user: creator)
    rule.revise!(actor: owner, policy: "allow", rationale: "Delegated by the operator")
    rule.revoke!(actor: owner)

    events = rule.audit_events.reload
    expect(events.map(&:event_type)).to eq(%w[ created updated revoked ])
    expect(events.map(&:actor_user)).to eq([ creator, owner, owner ])
    expect(events.map { |event| event.snapshot.fetch("policy") }).to eq(%w[ ask allow allow ])
    expect(events.second.changed_fields).to include("policy", "rationale")
    expect(events.last.snapshot.fetch("revoked_at")).to be_present
    expect { events.first.update!(event_type: "updated") }.to raise_error(ActiveRecord::ReadOnlyRecord, /append-only/)
    expect { events.first.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord, /append-only/)
  end

  it "revokes idempotently and excludes revoked rules from active queries" do
    rule = create_rule

    expect { 2.times { rule.revoke!(actor: owner) } }.to change { rule.audit_events.count }.by(1)
    expect(described_class.active).not_to include(rule)
    expect { rule.update!(policy: "deny") }.to raise_error(ActiveRecord::RecordInvalid, /cannot be changed/)
    expect { rule.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord, /revoked, not destroyed/)
  end

  it "requires explicit future-role semantics" do
    snapshot_rule = create_rule(
      subject_selector_type: "eligible_roles", subject_selector_id: nil,
      subject_role_keys: %w[ reviewer implementer reviewer ]
    )
    expect(snapshot_rule).not_to be_dynamic_future_roles
    expect(snapshot_rule.subject_role_keys).to eq(%w[ implementer reviewer ])

    dynamic_rule = described_class.new(rule_attributes.merge(
      subject_selector_type: "eligible_roles", subject_selector_id: nil,
      subject_role_keys: [], dynamic_future_roles: true
    ))
    expect(dynamic_rule).to be_valid

    scoped_dynamic = described_class.new(rule_attributes.merge(dynamic_future_roles: true))
    expect(scoped_dynamic).not_to be_valid
    expect(scoped_dynamic.errors[:dynamic_future_roles]).to be_present
  end

  it "canonicalizes normalized scope and structured provenance before storing history" do
    rule = create_rule(
      resource_scope: { database: "app", repository_id: repository.id },
      constraints: { destinations: [ :github, "syrus" ] },
      provenance: { request: { kind: :operator } }
    )

    expect(rule.resource_scope.keys).to eq(%w[ database repository_id ])
    expect(rule.constraints).to eq("destinations" => %w[ github syrus ])
    expect(rule.audit_events.first.snapshot.fetch("provenance"))
      .to eq("request" => { "kind" => "operator" })
  end
end
