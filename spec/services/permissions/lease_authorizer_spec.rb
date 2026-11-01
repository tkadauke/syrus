require "rails_helper"

RSpec.describe Permissions::LeaseAuthorizer do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:job) { Factories.job_record(user: owner, repository:, state: "running") }
  let(:chat_session) { ChatSession.create!(user: owner, title: "Permission lease") }
  let(:schema) do
    Permissions::ResourceScopeSchema.new(
      type: :repository,
      normalize: ->(scope, context:) { { repository_id: Integer(scope[:repository_id] || scope.fetch("repository_id")) } },
      compare: ->(left, right, context:) { left == right ? :equal : :disjoint }
    )
  end
  let(:descriptor) do
    Permissions::CapabilityDescriptor.new(
      capability: "syrus.jobs@v1", operation: "syrus.jobs/cancel@v1",
      effects: %i[internal_write destructive], risk: :high,
      requestable_roles: %w[implementer], defaults: { implementer: :ask },
      maximum_autonomy: :permanent, authority_durations: %i[invocation chat_session job permanent],
      resource_scope: schema, classifier: ->(_arguments) { { operation: "syrus.jobs/cancel@v1", confidence: :certain } },
      fingerprint_normalizer: ->(arguments) { arguments }, redactor: ->(arguments) { arguments }
    )
  end
  let(:context) { { subject_selector_type: "workflow_role", subject_selector_id: "implementer" } }

  def issue(duration, **attributes)
    Permissions::AuthorityGrant.issue!(
      duration:, descriptor:, owner:, actor: owner, subject_selector_type: "workflow_role",
      subject_selector_id: "implementer", role: "implementer", resource_scope: { repository_id: repository.id },
      context:, arguments: { job_id: job.id }, **attributes
    )
  end

  def authorize(arguments: { job_id: job.id }, extra_context: {}, rules: [])
    described_class.call(descriptor:, owner:, role: "implementer",
      resource_scope: { repository_id: repository.id }, context: context.merge(extra_context), arguments:, rules:)
  end

  it "claims an exact invocation once and rejects changed arguments" do
    lease = issue(:invocation)

    expect(authorize(arguments: { job_id: job.id + 1 })).not_to be_authorized
    first = authorize
    second = authorize

    expect(first).to be_authorized
    expect(first.lease).to eq(lease)
    expect(second).not_to be_authorized
    expect(lease.reload.used_count).to eq(1)
  end

  it "ends chat-session and Job leases with their owning lifecycle" do
    chat_lease = issue(:chat_session, chat_session:)
    job_lease = issue(:job, job:)

    expect(authorize(extra_context: { chat_session_id: chat_session.id }).lease).to eq(chat_lease)
    expect(authorize(extra_context: { job_id: job.id }).lease).to eq(job_lease)

    chat_session.update!(deleted_at: Time.current, deleted_by_user: owner)
    job.update_columns(state: "closed", finished_at: Time.current)

    expect(authorize(extra_context: { chat_session_id: chat_session.id })).not_to be_authorized
    expect(authorize(extra_context: { job_id: job.id })).not_to be_authorized
  end

  it "honors expiry, revocation, and bounded use counts on every invocation" do
    lease = issue(:job, job:, max_uses: 2, expires_at: 1.hour.from_now)

    2.times { expect(authorize(extra_context: { job_id: job.id })).to be_authorized }
    expect(authorize(extra_context: { job_id: job.id })).not_to be_authorized

    replacement = issue(:job, job:)
    replacement.revoke!(actor: owner)
    expect(authorize(extra_context: { job_id: job.id })).not_to be_authorized
    expect { replacement.update!(max_uses: 3) }.to raise_error(ActiveRecord::RecordInvalid, /cannot be changed/)

    expired = issue(:job, job:, expires_at: 1.minute.from_now)
    expired.update_column(:expires_at, 1.minute.ago)
    expect(authorize(extra_context: { job_id: job.id })).not_to be_authorized
  end

  it "re-evaluates effect and argument constraints for each use" do
    lease = issue(:job, job:, constraints: { job_id: job.id })

    expect(authorize(extra_context: { job_id: job.id })).to be_authorized
    expect(authorize(arguments: { job_id: job.id + 1 }, extra_context: { job_id: job.id })).not_to be_authorized
    expect(lease.reload.used_count).to eq(1)
  end

  it "rejects leases that exceed a non-delegable ceiling" do
    ceiling = Permissions::PolicyRule.new(
      id: "provider-ceiling", layer: :provider, policy: :ask, source: "spec", delegable: false
    )

    expect { issue(:job, job:, rules: [ ceiling ]) }
      .to raise_error(ArgumentError, /effective policy ceiling/)
  end

  it "represents permanent authority as an audited durable rule" do
    rule = issue(:permanent)

    expect(rule).to be_a(PermissionRule)
    expect(rule).to have_attributes(policy: "allow", policy_layer: "agent")
    expect(rule.provenance).to include("authority_duration" => "permanent")
    expect(rule.audit_events.pluck(:event_type)).to eq([ "created" ])
  end

  it "rejects unsupported durations and descriptor autonomy escalation" do
    limited = Permissions::CapabilityDescriptor.new(**descriptor.to_h.merge(
      maximum_autonomy: :invocation, authority_durations: [ :invocation ]
    ))

    expect do
      Permissions::AuthorityGrant.issue!(duration: :job, descriptor: limited, owner:, actor: owner,
        subject_selector_type: "workflow_role", subject_selector_id: "implementer", role: "implementer",
        resource_scope: { repository_id: repository.id }, context:, arguments: {}, job:)
    end.to raise_error(ArgumentError, /unsupported authority duration/)
  end

  it "applies a provider maximum duration when no shorter expiry is requested" do
    bounded = Permissions::CapabilityDescriptor.new(**descriptor.to_h.merge(maximum_duration: 30.minutes))
    before = Time.current
    lease = Permissions::AuthorityGrant.issue!(duration: :chat_session, descriptor: bounded, owner:, actor: owner,
      subject_selector_type: "workflow_role", subject_selector_id: "implementer", role: "implementer",
      resource_scope: { repository_id: repository.id }, context:, arguments: {}, chat_session:)

    expect(lease.expires_at).to be_between(before + 30.minutes, Time.current + 30.minutes)
  end
end
