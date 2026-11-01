require "rails_helper"

RSpec.describe "authorization checkpoint failure recovery", :ci_only do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }

  before { clear_enqueued_jobs }

  def checkpointed_run_request
    job = Factories.job(user:, repository:)
    workflow = job.workflows.first
    run = workflow.runs.first
    workflow.update!(state: "running")
    run.step.update!(state: "running")
    run.update!(state: "running", started_at: Time.current)

    request = authorization_request(origin: run)
    request.checkpoint_authorization!(payload: {
      provider: "codex",
      continuation: { tool_name: "protected_write", tool_call_id: "call-1" }
    })
    [ request, run ]
  end

  def authorization_request(origin:)
    ChatPendingAction.create!(
      request_kind: "authorization_request",
      user:,
      repository:,
      origin:,
      subject: user,
      runtime_role: origin.is_a?(Run) ? "implementer" : "interactive_chat",
      deduplication_key: "checkpoint-recovery-#{origin.class.name}-#{origin.id}-#{SecureRandom.hex(4)}",
      purpose: "Exercise a protected operation"
    )
  end

  def approved_invocation(origin:, fingerprint: "sha256:protected-write", authority: nil)
    request = authorization_request(origin:)
    item = request.authorization_items.create!(
      kind: "operation",
      capability: "test.resource@v1",
      operation: "test.resource/write@v1",
      operation_version: 1,
      resource_type: "test_resource",
      resource_scope: { resource_id: 7 },
      normalized_arguments: { value: "redacted" },
      invocation_fingerprint: fingerprint,
      effects: %w[external_write]
    )
    item.decide!("approved", principal: user, duration: "invocation", resulting_authority: authority)
    AuthorizedInvocation.issue!(pending_action_item: item, authority:, tool_name: "protected_write")
  end

  def claim(invocation, revalidation: true, origin_resumable: true, claim_key: "dispatch-1")
    invocation.claim!(
      fingerprint: invocation.invocation_fingerprint,
      claimant: user,
      claim_key:,
      revalidate: ->(_) { revalidation },
      origin_resumable: ->(_) { origin_resumable }
    )
  end

  it "recovers when a worker dies after persisting a Run continuation but before claiming it" do
    request, run = checkpointed_run_request
    clear_enqueued_jobs

    first = AuthorizationContinuations::Coordinator.call(
      request:,
      outcome: :approved,
      tool_result: { "content" => "written" }
    )

    expect(first.status).to eq(:delivered)
    expect(request.reload).to have_attributes(checkpoint_state: "resuming", resume_attempts: 1)

    # The first worker is gone. A duplicate decision delivery must not rewrite
    # the continuation, while a replacement RunJob can still claim it.
    duplicate = AuthorizationContinuations::Coordinator.call(
      request: request.reload,
      outcome: :approved,
      tool_result: { "content" => "different" }
    )
    replacement_worker = RunJob.new
    replacement_worker.instance_variable_set(:@run, run.reload)

    expect(duplicate.status).to eq(:already_claimed)
    expect(replacement_worker.send(:pending_authorization_continuation?)).to be(true)
    expect(replacement_worker.send(:claim_authorization_continuation!)).to be(true)
    expect(request.reload).to have_attributes(checkpoint_state: "resumed", resume_attempts: 1)
    expect(run.reload.prompt).to include("written")
    expect(run.prompt).not_to include("different")
    expect(enqueued_jobs.count { |job| job[:job] == RunJob }).to eq(1)
  end

  it "makes duplicate execution delivery observable without executing twice" do
    chat = ChatSession.create!(user:, repository:)
    invocation = approved_invocation(origin: chat)
    executions = 0

    first = claim(invocation)
    executions += 1 if first.claimed?
    duplicate = claim(invocation.reload)
    executions += 1 if duplicate.claimed?
    invocation.reload.complete!(claim_key: "dispatch-1", status: :succeeded)

    expect(first).to be_claimed
    expect(duplicate).to be_already_claimed
    expect(executions).to eq(1)
    expect(invocation.reload).to be_succeeded
  end

  it "does not execute an approval after its origin becomes stale" do
    chat = ChatSession.create!(user:, repository:)
    request = authorization_request(origin: chat)
    request.checkpoint_authorization!(payload: { cursor: "before-stop" })
    chat.update!(stop_requested_at: Time.current)
    clear_enqueued_jobs

    result = AuthorizationContinuations::Coordinator.call(
      request: request.reload,
      outcome: :approved,
      tool_result: { "content" => "must not be delivered" }
    )

    expect(result.status).to eq(:non_resumable)
    expect(request.reload).to have_attributes(
      checkpoint_state: "non_resumable",
      last_resume_error: "origin_no_longer_resumable"
    )
    expect(chat.reload.chat_queued_messages).to be_empty
    expect(enqueued_jobs).to be_empty
  end

  {
    "plugin disablement" => "plugin_disabled",
    "resource removal" => "resource_removed"
  }.each do |failure, reason|
    it "invalidates an approved invocation when execution revalidation detects #{failure}" do
      chat = ChatSession.create!(user:, repository:)
      invocation = approved_invocation(origin: chat)
      dispatched = false

      result = invocation.claim!(
        fingerprint: invocation.invocation_fingerprint,
        claimant: user,
        claim_key: "dispatch-after-#{reason}",
        revalidate: ->(_) { reason },
        origin_resumable: ->(_) { true }
      )
      dispatched = true if result.claimed?

      expect(result.status).to eq(:revalidation_failed)
      expect(dispatched).to be(false)
      expect(invocation.reload).to have_attributes(
        state: "invalidated",
        invalidation_reason: reason,
        claimed_at: nil
      )
    end
  end

  it "invalidates the token when authority is revoked between approval and execution" do
    chat = ChatSession.create!(user:, repository:)
    lease = PermissionLease.create!(
      owner_user: user,
      subject_selector_type: "workflow_role",
      subject_selector_id: "implementer",
      subject_repository: repository,
      capability: "test.resource@v1",
      operation: "test.resource/write@v1",
      resource_type: "test_resource",
      resource_scope: { resource_id: 7 },
      constraints: {},
      effects: %w[external_write],
      duration_kind: "invocation",
      invocation_fingerprint: "sha256:protected-write",
      max_uses: 1,
      issued_by_user: user
    )
    invocation = approved_invocation(origin: chat, authority: lease)

    lease.revoke!(actor: user)

    expect(invocation.reload).to have_attributes(
      state: "invalidated",
      invalidation_reason: "authority_revoked",
      claimed_at: nil
    )
    expect(claim(invocation).status).to eq(:unavailable)
  end
end
