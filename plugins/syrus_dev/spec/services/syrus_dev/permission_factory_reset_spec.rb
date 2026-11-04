require "rails_helper"

RSpec.describe SyrusDev::PermissionFactoryReset do
  let(:admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }

  before { PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true) }

  def custom_rule
    PermissionRule.create!(
      owner_user: owner, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      subject_role_keys: [], subject_repository: repository,
      capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
      resource_type: "job", resource_scope: {}, policy: "allow", constraints: {},
      policy_layer: "agent", source: "operator", provenance: {}, created_by_user: owner, updated_by_user: owner
    )
  end

  def temporary_lease
    PermissionLease.create!(
      owner_user: owner, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      subject_repository: repository, capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
      resource_type: "job", resource_scope: {}, constraints: {}, effects: [],
      duration_kind: "job", job: Factories.job_record(user: owner, repository: repository), issued_by_user: owner
    )
  end

  def pending_request
    job = Factories.job_record(user: owner, repository: repository)
    ChatPendingAction.create!(
      request_kind: "authorization_request", user: owner, repository:, origin: job,
      subject: owner, runtime_role: "implementer", deduplication_key: "factory-reset-request"
    ).tap do |record|
      record.authorization_items.create!(
        kind: "operation", capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
        operation_version: 1, resource_type: "job", resource_scope: {}, normalized_arguments: {},
        invocation_fingerprint: "sha256:reset", effects: [ "external_write" ], policy_chain: [],
        decisive_rule: {}, requested_durations: [ "invocation" ]
      )
      record.checkpoint_authorization!
    end
  end

  it "previews and transactionally resets a repository without deleting audit history" do
    rule = custom_rule
    lease = temporary_lease
    request = pending_request
    approved_item = request.authorization_items.sole
    approved_item.decide!("approved", principal: admin, duration: "invocation", resulting_authority: rule)
    invocation = AuthorizedInvocation.issue!(
      pending_action_item: approved_item, authority: rule, tool_name: "cancel_job"
    )
    pending_item = request.authorization_items.create!(
      kind: "capability_possession", capability: "syrus.jobs@v1", resource_type: "job",
      resource_scope: {}, normalized_arguments: {}, effects: [], policy_chain: [], decisive_rule: {},
      requested_durations: [ "invocation" ]
    )
    service = described_class.new(scope_type: "repository", scope_id: repository.id, initiated_by: admin)
    preview = service.preview

    expect(preview.counts).to include(
      "rules" => 1, "leases" => 1, "authorized_invocations" => 1,
      "pending_requests" => 1, "resumptions" => 1,
      "profile_selections" => 0
    )

    result = service.confirm!(confirmation_digest: preview.confirmation_digest)

    expect(result).to be_changed
    expect(rule.reload).to have_attributes(revoked_by_user: admin)
    expect(rule.audit_events.pluck(:event_type)).to eq(%w[created revoked])
    expect(lease.reload).to have_attributes(revoked_by_user: admin)
    expect(invocation.reload).to have_attributes(state: "invalidated")
    expect(request.reload).to have_attributes(state: "cancelled", checkpoint_state: "cancelled")
    expect(approved_item.reload).to be_approved
    expect(pending_item.reload).to be_non_actionable
    expect(result.record).to have_attributes(
      initiated_by_user: admin, scope_type: "repository", scope_id: repository.id.to_s,
      default_version: "permissions-factory@v1", outcome: "succeeded"
    )
    expect(Repository.exists?(repository.id)).to be(true)
    expect(User.exists?(owner.id)).to be(true)
  end

  it "is idempotent once factory defaults are installed" do
    service = described_class.new(scope_type: "user", scope_id: owner.id, initiated_by: admin)
    first = service.preview
    service.confirm!(confirmation_digest: first.confirmation_digest)
    second = service.preview

    expect(second.counts.values_at("rules", "leases", "pending_requests", "resumptions", "profile_selections", "factory_rules_to_create"))
      .to all(eq(0))
    expect(service.confirm!(confirmation_digest: second.confirmation_digest)).not_to be_changed
    expect(Permissions::Management.new(owner).current_profile(subject_selector_type: "interactive_chat"))
      .to eq("ask_on_first_use@v1")
  end

  it "rejects stale confirmation and records the failed outcome without changing authority" do
    rule = custom_rule
    service = described_class.new(scope_type: "user", scope_id: owner.id, initiated_by: admin)
    preview = service.preview
    custom_rule

    expect { service.confirm!(confirmation_digest: preview.confirmation_digest) }
      .to raise_error(ArgumentError, "permission reset preview is stale")
    expect(rule.reload.revoked_at).to be_nil
    expect(SyrusDev::PermissionFactoryResetRecord.last).to have_attributes(outcome: "failed", initiated_by_user: admin)
  end

  it "is unavailable when the development plugin is disabled" do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: false)

    expect { described_class.new(scope_type: "instance", initiated_by: admin) }
      .to raise_error(ArgumentError, "syrus_dev plugin is disabled")
  end
end
