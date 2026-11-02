require "rails_helper"

RSpec.describe Permissions::AuthorizationRequestRouter, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:first_origin) { Factories.job_record(user:, repository:) }
  let(:second_origin) { Factories.job_record(user:, repository:) }

  def route(origin: first_origin, key: "scheduled:mysql.data/write:fingerprint", capability: "mysql.data", now: Time.current)
    described_class.route!(
      user:, repository:, origin:, subject: user, runtime_role: "background_coworker",
      deduplication_key: key, purpose: "Apply a scheduled correction",
      capability:, operation: "write", now:,
      occurrence_metadata: { fire_window: now.iso8601 },
      item_attributes: {
        kind: "operation", operation_version: 1, resource_type: "mysql_connection",
        resource_scope: { connection_id: 4 }, normalized_arguments: { sql_digest: "sha256:abc" },
        invocation_fingerprint: "sha256:fingerprint", effects: %w[credential_use external_write],
        policy_chain: [], decisive_rule: {}, requested_durations: %w[invocation job]
      }
    )
  end

  it "associates equivalent schedule fires with one request without checkpointing the later fire" do
    first = route
    second = route(origin: second_origin)

    expect(first).to be_created
    expect(first).to be_checkpoint_required
    expect(second).to be_reused
    expect(second).to be_continue_ungated
    expect(second.request).to eq(first.request)
    expect(first.request.occurrences.order(:id).pluck(:origin_type, :origin_id)).to eq([
      [ "Job", first_origin.id ], [ "Job", second_origin.id ]
    ])
    expect(second_origin.related_authorization_requests).to contain_exactly(first.request)
    expect(ChatPendingAction.where(deduplication_key: "scheduled:mysql.data/write:fingerprint").count).to eq(1)
  end

  it "suppresses an equivalent request during the short denial cooldown" do
    denied_at = Time.current
    first = route(now: denied_at)
    first.request.authorization_items.first.decide!("denied", principal: user)
    first.request.update!(state: "rejected", rejected_at: denied_at)

    result = route(origin: second_origin, now: denied_at + 5.minutes)

    expect(result.status).to eq(:denial_cooldown)
    expect(result.request).to eq(first.request)
    expect(result).to be_continue_ungated
    expect(first.request.occurrences.count).to eq(2)
    expect(second_origin.related_authorization_requests).to contain_exactly(first.request)
  end

  it "caps active requests for the same subject and capability" do
    stub_const("Permissions::AuthorizationRequestRouter::MAX_ACTIVE_PER_SUBJECT_CAPABILITY", 2)
    route(key: "first")
    route(key: "second")

    result = route(origin: second_origin, key: "third")

    expect(result.status).to eq(:request_cap)
    expect(result.request).to be_nil
    expect(result).to be_continue_ungated
    expect(ChatPendingAction.where(request_kind: "authorization_request").count).to eq(2)
  end

  it "does not apply another repository's active-request cap" do
    stub_const("Permissions::AuthorizationRequestRouter::MAX_ACTIVE_PER_SUBJECT_CAPABILITY", 1)
    route
    other_repository = Factories.repository(user:)
    other_origin = Factories.job_record(user:, repository: other_repository)

    result = described_class.route!(
      user:, repository: other_repository, origin: other_origin, subject: user, runtime_role: "background_coworker",
      deduplication_key: "other-repository", purpose: "Apply a scheduled correction",
      capability: "mysql.data", operation: "write",
      item_attributes: {
        kind: "operation", operation_version: 1, resource_type: "mysql_connection",
        resource_scope: { connection_id: 4 }, normalized_arguments: { sql_digest: "sha256:abc" },
        invocation_fingerprint: "sha256:other", effects: %w[credential_use external_write],
        policy_chain: [], decisive_rule: {}, requested_durations: %w[invocation job]
      }
    )

    expect(result).to be_created
    expect(result.request.repository).to eq(other_repository)
  end
end
