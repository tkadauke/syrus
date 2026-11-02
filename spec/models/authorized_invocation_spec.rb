require "rails_helper"

RSpec.describe AuthorizedInvocation, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job_record(user:, repository:, state: "running") }

  def approved_item(fingerprint: "sha256:exact")
    request = ChatPendingAction.create!(
      request_kind: "authorization_request", user:, origin: job, subject: user,
      deduplication_key: "authorized-invocation-#{fingerprint}"
    )
    item = request.authorization_items.create!(
      kind: "operation", capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
      operation_version: 1, resource_type: "job", invocation_fingerprint: fingerprint
    )
    item.decide!("approved", principal: user, duration: "invocation")
    item
  end

  def issue(item = approved_item, authority: nil)
    described_class.issue!(pending_action_item: item, authority:, tool_name: "cancel_job",
      execution_authority: { role: :implementer }, audit_payload: { job_id: job.id })
  end

  def claim(invocation, **overrides)
    invocation.claim!(**{
      fingerprint: invocation.invocation_fingerprint, claimant: user, claim_key: "dispatch-1",
      revalidate: ->(_claim) { true }, origin_resumable: ->(_claim) { true }
    }.merge(overrides))
  end

  it "copies an approved fingerprint into immutable audit data" do
    item = approved_item
    invocation = issue(item)

    expect(invocation).to have_attributes(state: "issued", execution_authority: { "role" => "implementer" })
    expect(issue(item)).to eq(invocation)
    expect { invocation.update!(invocation_fingerprint: "changed") }
      .to raise_error(ActiveRecord::RecordInvalid, /immutable/)
  end

  it "claims exactly once and makes dispatch retries observable without authorizing another execution" do
    invocation = issue

    expect(claim(invocation.reload)).to be_claimed
    expect(claim(invocation.reload)).to be_already_claimed
    expect(claim(invocation.reload, claim_key: "dispatch-2").status).to eq(:unavailable)

    invocation.complete!(claim_key: "dispatch-1", status: :succeeded, result: job)
    expect(invocation.reload).to have_attributes(state: "succeeded", result: job)
    expect { invocation.complete!(claim_key: "dispatch-1", status: :succeeded, result: job) }.not_to raise_error
  end

  it "prevents claimed and completed invocations from being reset or rewritten" do
    invocation = issue
    claim(invocation)

    expect { invocation.update!(state: "issued", claim_key: nil, claimed_by: nil, claimed_at: nil) }
      .to raise_error(ActiveRecord::RecordInvalid, /lifecycle is immutable/)

    invocation.reload.complete!(claim_key: "dispatch-1", status: :succeeded, result: job)
    expect { invocation.update!(state: "failed", result_status: "failed") }
      .to raise_error(ActiveRecord::RecordInvalid, /lifecycle is immutable/)
    expect { invocation.update!(claim_key: "rewritten-dispatch") }
      .to raise_error(ActiveRecord::RecordInvalid, /lifecycle is immutable/)
  end

  it "rejects an inexact fingerprint before revalidation or dispatch" do
    invocation = issue
    revalidated = false

    result = claim(invocation, fingerprint: "sha256:different",
      revalidate: ->(_claim) { revalidated = true })

    expect(result.status).to eq(:fingerprint_mismatch)
    expect(revalidated).to be(false)
    expect(invocation.reload).to have_attributes(state: "invalidated", invalidation_reason: "invocation_fingerprint_mismatch")
  end

  it "revalidates under the claim lock and invalidates a rejected invocation" do
    invocation = issue

    result = claim(invocation, revalidate: ->(_claim) { "permission_rule_revoked" })

    expect(result.status).to eq(:revalidation_failed)
    expect(invocation.reload).to have_attributes(state: "invalidated", invalidation_reason: "permission_rule_revoked")
  end

  it "marks a stale origin non-resumable without consuming the invocation" do
    invocation = issue

    result = claim(invocation, origin_resumable: ->(_claim) { false })

    expect(result.status).to eq(:non_resumable)
    expect(invocation.reload).to have_attributes(state: "non_resumable", claimed_at: nil)
  end

  it "invalidates unclaimed tokens when their lease is revoked but leaves claimed calls alone" do
    first_lease = create_lease
    unclaimed = issue(approved_item(fingerprint: "sha256:first"), authority: first_lease)
    first_lease.revoke!(actor: user)
    expect(unclaimed.reload).to be_invalidated

    second_lease = create_lease
    claimed = issue(approved_item(fingerprint: "sha256:second"), authority: second_lease)
    claim(claimed)
    second_lease.revoke!(actor: user)
    expect(claimed.reload).to be_claimed
  end

  it "refuses to issue a new invocation from revoked authority" do
    lease = create_lease
    lease.revoke!(actor: user)

    expect { issue(approved_item(fingerprint: "sha256:revoked"), authority: lease) }
      .to raise_error(ActiveRecord::RecordInvalid, /Authority has been revoked/)
  end

  it "invalidates an unclaimed token when its durable rule is revoked" do
    rule = PermissionRule.create!(
      owner_user: user, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      subject_role_keys: [], capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
      resource_type: "job", resource_scope: { job_id: job.id }, policy: "allow", constraints: {},
      policy_layer: "agent", source: "operator", provenance: {}, created_by_user: user, updated_by_user: user
    )
    invocation = issue(approved_item(fingerprint: "sha256:rule"), authority: rule)

    rule.revoke!(actor: user)

    expect(invocation.reload).to have_attributes(state: "invalidated", invalidation_reason: "authority_revoked")
  end

  def create_lease
    PermissionLease.create!(
      owner_user: user, subject_selector_type: "workflow_role", subject_selector_id: "implementer",
      subject_repository: repository, capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
      resource_type: "job", resource_scope: { job_id: job.id }, constraints: {}, effects: [],
      duration_kind: "job", job:, issued_by_user: user
    )
  end
end
