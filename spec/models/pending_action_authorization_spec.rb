require "rails_helper"

RSpec.describe "surface-neutral pending action authorization", :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  def create_request(**attributes)
    ChatPendingAction.create!({
      request_kind: "authorization_request",
      user: user,
      repository: repository,
      origin: job,
      subject: user,
      runtime_role: "implementer",
      deduplication_key: "agent:#{user.id}:mysql.data/write:fingerprint",
      purpose: "Apply the requested data correction"
    }.merge(attributes))
  end

  def create_item(request, **attributes)
    request.authorization_items.create!({
      kind: "operation",
      capability: "mysql.data",
      operation: "write",
      operation_version: 1,
      resource_type: "mysql_connection",
      resource_scope: { connection_id: 4 },
      normalized_arguments: { sql_digest: "sha256:abc" },
      invocation_fingerprint: "sha256:fingerprint",
      effects: %w[external_write credential_use],
      policy_chain: [],
      decisive_rule: {},
      requested_durations: %w[invocation job]
    }.merge(attributes))
  end

  it "persists an authorization request without a chat and finds its active duplicate" do
    request = create_request

    expect(request.chat_session).to be_nil
    expect(request.origin).to eq(job)
    expect(request.subject).to eq(user)
    expect(ChatPendingAction.find_equivalent(request.deduplication_key)).to eq(request)
    expect(request.transitions.pluck(:event_type, :to_state)).to eq([ [ "created", "pending" ] ])
  end

  it "atomically reuses an equivalent active authorization request" do
    request = create_request
    duplicate = ChatPendingAction.create_or_find_authorization_request!(
      user: user,
      repository: repository,
      origin: job,
      subject: user,
      deduplication_key: request.deduplication_key
    )

    expect(duplicate).to eq(request)
    expect(ChatPendingAction.where(deduplication_key: request.deduplication_key).count).to eq(1)

    request.mark_non_actionable!("Connection removed")
    replacement = create_request
    expect(replacement).not_to eq(request)
  end

  it "keeps legacy chat pending actions and derives their origin" do
    chat = ChatSession.create!(user: user, repository: repository)
    action = chat.pending_actions.create!(action: "pause_landing_queue", payload: {})

    expect(action).to be_legacy_action
    expect(action.origin).to eq(chat)
    expect(action.user).to eq(user)
  end

  it "destroys pending actions and their transition history through existing ownership cascades" do
    request = ChatPendingAction.create!(
      request_kind: "authorization_request",
      user: user,
      origin: user,
      subject: user,
      deduplication_key: "user-owned-request"
    )
    item = create_item(request)
    transition_ids = request.transitions.ids

    expect { request.destroy! }.to change(ChatPendingAction, :count).by(-1)
      .and change(PendingActionItem, :count).by(-1)
      .and change(PendingActionTransition, :count).by(-transition_ids.size)
    expect(PendingActionItem.exists?(item.id)).to be(false)

    owned_request = ChatPendingAction.create!(
      request_kind: "authorization_request",
      user: user,
      origin: user,
      subject: user,
      deduplication_key: "second-user-owned-request"
    )

    expect { user.destroy! }.to change(ChatPendingAction.where(id: owned_request.id), :count).from(1).to(0)
  end

  it "destroys legacy actions with their chat while preserving chat-origin authorization requests" do
    chat = ChatSession.create!(user: user, repository: repository)
    legacy = chat.pending_actions.create!(action: "pause_landing_queue", payload: {})
    authorization = create_request(
      chat_session: chat,
      origin: chat,
      deduplication_key: "chat-authorization-request"
    )

    chat.destroy!

    expect(ChatPendingAction.exists?(legacy.id)).to be(false)
    expect(authorization.reload.chat_session).to be_nil
    expect(authorization.origin).to be_nil
  end

  it "decides compound items independently and requires every item before invocation" do
    request = create_request
    possession = request.authorization_items.create!(
      kind: "capability_possession",
      capability: "mysql.data",
      resource_type: "mysql_connection",
      resource_scope: { connection_id: 4 },
      normalized_arguments: {},
      effects: [],
      policy_chain: [],
      decisive_rule: {},
      requested_durations: %w[job]
    )
    operation = create_item(request)
    operation.prerequisites << possession

    expect(operation.prerequisites_approved?).to be(false)
    expect(request.ready_for_authorized_invocation?).to be(false)

    expect(possession.decide!("approved", principal: user, duration: "job")).to be(true)
    expect(operation.prerequisites_approved?).to be(true)
    expect(request.ready_for_authorized_invocation?).to be(false)

    expect(operation.decide!("approved", principal: user, duration: "invocation")).to be(true)
    expect(request.ready_for_authorized_invocation?).to be(true)
    expect(operation.decide!("denied", principal: user)).to be(false)
  end

  it "rejects prerequisite relationships across requests" do
    item = create_item(create_request)
    other = create_item(create_request(deduplication_key: "other"))

    expect { item.prerequisites << other }.to raise_error(ActiveRecord::RecordInvalid, /same pending action/)
  end

  it "rejects cyclic prerequisite relationships" do
    request = create_request
    first = create_item(request)
    second = create_item(request, invocation_fingerprint: "sha256:second")
    second.prerequisites << first

    expect { first.prerequisites << second }.to raise_error(ActiveRecord::RecordInvalid, /cycle/)
  end

  it "marks unresolved items and their request non-actionable without denying them" do
    request = create_request
    item = create_item(request)

    expect(request.mark_non_actionable!("The resource was removed")).to be(true)

    expect(request.reload).to be_non_actionable
    expect(request.non_actionable_reason).to eq("The resource was removed")
    expect(item.reload).to be_non_actionable
    expect(item.decision_principal).to be_nil
    expect(ChatPendingAction.find_equivalent(request.deduplication_key)).to be_nil
  end

  it "tracks delivery attempts and metadata independently of decisions" do
    request = create_request

    request.record_delivery_failure!(RuntimeError.new("inbox unavailable"), metadata: { channel: "inbox" })
    expect(request).to have_attributes(delivery_state: "failed", delivery_attempts: 1, delivery_metadata: { "channel" => "inbox" })

    request.record_delivery!(metadata: { notification_id: 12 })
    expect(request).to have_attributes(delivery_state: "delivered", delivery_attempts: 2, last_delivery_error: nil)
    expect(request.delivery_metadata).to eq("channel" => "inbox", "notification_id" => 12)
  end

  it "persists and resumes an authorization checkpoint with append-only lifecycle transitions" do
    request = create_request
    payload = {
      provider: "codex",
      session_id: "session-123",
      continuation: { tool_name: "mysql_execute", tool_call_id: "call-456" }
    }

    expect(request.checkpoint_authorization!(payload: payload)).to be(true)
    expect(request.reload).to have_attributes(
      checkpoint_state: "waiting",
      checkpoint_payload: payload.deep_stringify_keys,
      resume_attempts: 0
    )
    expect(request.checkpointed_at).to be_present
    expect(job.reload).to be_waiting_for_permission

    expect(request.begin_authorization_resume!).to be(true)
    expect(request.fail_authorization_resume!(RuntimeError.new("worker unavailable"))).to be(true)
    expect(request.reload).to have_attributes(
      checkpoint_state: "resume_failed",
      resume_attempts: 1,
      last_resume_error: "RuntimeError: worker unavailable"
    )

    expect(request.begin_authorization_resume!).to be(true)
    expect(request.complete_authorization_resume!).to be(true)
    expect(request.reload).to have_attributes(checkpoint_state: "resumed", resume_attempts: 2)
    expect(request.resumed_at).to be_present
    expect(job.reload).not_to be_waiting_for_permission
    expect(request.transitions.where(event_type: "checkpoint_state_changed").pluck(:from_state, :to_state)).to eq([
      [ nil, "waiting" ],
      [ "waiting", "resuming" ],
      [ "resuming", "resume_failed" ],
      [ "resume_failed", "resuming" ],
      [ "resuming", "resumed" ]
    ])
  end

  it "derives waiting blockers for chat, Job, Workflow, and Run origins without changing their states" do
    chat = ChatSession.create!(user: user, repository: repository)
    execution_job = Factories.job(user: user, repository: repository)
    workflow = execution_job.workflows.first
    run = workflow.runs.first
    original_states = [ execution_job.state, workflow.state, run.state ]

    [ chat, execution_job, workflow, run ].each_with_index do |origin, index|
      request = create_request(origin: origin, deduplication_key: "checkpoint-origin-#{index}")
      expect(request.checkpoint_authorization!(payload: { "cursor" => index })).to be(true)
      expect(origin.reload).to be_waiting_for_permission
    end

    expect([ execution_job.state, workflow.state, run.state ]).to eq(original_states)
  end

  it "cancels a waiting checkpoint when its request becomes obsolete" do
    request = create_request
    request.checkpoint_authorization!(payload: { cursor: 1 })

    expect(request.mark_non_actionable!("Resource removed")).to be(true)
    expect(request.reload.checkpoint_state).to eq("cancelled")
    expect(request.transitions.where(event_type: "checkpoint_state_changed").last).to have_attributes(
      from_state: "waiting",
      to_state: "cancelled"
    )
  end

  it "derives parent blockers from a Run-origin request" do
    execution_job = Factories.job(user: user, repository: repository)
    workflow = execution_job.workflows.first
    run = workflow.runs.first
    request = create_request(origin: run, deduplication_key: "run-parent-blockers")

    request.checkpoint_authorization!(payload: { cursor: 1 })

    expect(workflow.reload).to be_waiting_for_permission
    expect(execution_job.reload).to be_waiting_for_permission
  end

  it "rejects checkpoints on legacy actions and unsupported origins" do
    legacy = ChatSession.create!(user: user, repository: repository)
      .pending_actions.create!(action: "pause_landing_queue", payload: {})
    legacy.checkpoint_state = "waiting"
    legacy.checkpointed_at = Time.current
    expect(legacy).not_to be_valid

    request = create_request(origin: user, deduplication_key: "unsupported-checkpoint-origin")
    expect { request.checkpoint_authorization!(payload: {}) }
      .to raise_error(ActiveRecord::RecordInvalid, /does not support authorization checkpoints/)
  end

  it "records append-only request and item transitions" do
    request = create_request
    item = create_item(request)

    item.decide!("denied", principal: user, reason: "Use a read-only query")
    request.dismiss!

    expect(request.transitions.order(:sequence).pluck(:to_state)).to eq(%w[pending pending denied dismissed])
    expect { request.transitions.first.update!(event_type: "changed") }.to raise_error(ActiveRecord::ReadOnlyRecord, /append-only/)
    expect { request.transitions.first.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord, /append-only/)
  end
end
