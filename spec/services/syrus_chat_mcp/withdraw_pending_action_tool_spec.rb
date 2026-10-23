require "rails_helper"

RSpec.describe Mcp::Tools::WithdrawPendingActionTool do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(id, reason: nil)
    arguments = { pending_action_id: id }
    arguments[:reason] = reason if reason
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "withdraw_pending_action", arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def action(state: "pending", session: chat_session)
    session.pending_actions.create!(action: "pause_landing_queue", payload: {}, state: state)
  end

  before { clear_enqueued_jobs }

  it "rejects a pending action immediately, records the reason, and returns structured output" do
    pending_action = action
    action_count = ChatPendingAction.count
    message_count = chat_session.messages.where("content LIKE ?", "%pending_action_notification%").count
    response = call_tool(pending_action.id, reason: "Proposed against the wrong target")

    expect(response[:result][:isError]).to be_falsey
    expect(payload(response)).to eq(
      pending_action_id: pending_action.id,
      action: "pause_landing_queue",
      prior_state: "pending",
      resulting_state: "rejected",
      changed: true
    )
    expect(chat_session.messages.where("content LIKE ?", "%pending_action_notification%").count).to eq(message_count + 1)
    expect(enqueued_jobs).to include(hash_including(job: ChatTurnJob))
    expect(ChatPendingAction.count).to eq(action_count)
    expect(pending_action.reload).to have_attributes(
      state: "rejected",
      reason: "Proposed against the wrong target",
      rejected_at: be_present
    )
  end

  it "cancels queued and failed actions through their existing cancellable transition" do
    queued = chat_session.pending_actions.create!(
      action: "submit_chat_feedback",
      state: "queued",
      payload: { "job_id" => 123, "feedback" => "Please tighten this." }
    )
    failed = action(state: "failed")

    queued_response = call_tool(queued.id)
    failed_response = call_tool(failed.id)

    expect(payload(queued_response)).to include(prior_state: "queued", resulting_state: "cancelled", changed: true)
    expect(payload(failed_response)).to include(prior_state: "failed", resulting_state: "cancelled", changed: true)
    expect(queued.reload.cancelled_at).to be_present
  end

  it "returns an idempotent result for an already rejected or cancelled action" do
    rejected = action(state: "rejected")
    cancelled = action(state: "cancelled")

    expect(payload(call_tool(rejected.id))).to include(prior_state: "rejected", resulting_state: "rejected", changed: false)
    expect(payload(call_tool(cancelled.id))).to include(prior_state: "cancelled", resulting_state: "cancelled", changed: false)
  end

  it "refuses executing and completed actions without changing them" do
    confirming = action(state: "confirming")
    confirmed = action(state: "confirmed")

    [ confirming, confirmed ].each do |pending_action|
      response = call_tool(pending_action.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("cannot be withdrawn from state #{pending_action.state}")
      expect(pending_action.reload.state).to eq(pending_action.state)
    end
  end

  it "uses the locked current state when the caller holds a stale action instance" do
    pending_action = action
    stale = ChatPendingAction.find(pending_action.id)
    pending_action.update!(state: "confirmed", confirmed_at: Time.current)

    expect {
      PendingActions::Withdrawal.new(stale, user: user).call
    }.to raise_error(PendingActions::Withdrawal::NotWithdrawable, /state confirmed/)
    expect(stale.reload).to be_confirmed
  end

  it "does not expose actions from another chat or owner" do
    same_owner_action = action(session: ChatSession.create!(user: user))
    other_owner_action = action(session: ChatSession.create!(user: Factories.user))

    [ same_owner_action, other_owner_action ].each do |pending_action|
      response = call_tool(pending_action.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("not found in this chat")
      expect(pending_action.reload).to be_pending
    end
  end

  it "refuses member-level withdrawal for a grouped action" do
    group = PendingActionGroup.create_with_members!(
      chat_session: chat_session,
      member_attributes: [ { action: "pause_landing_queue", payload: {} }, { action: "resume_landing_queue", payload: {} } ]
    )
    member = group.chat_pending_actions.first

    response = call_tool(member.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("reject the whole group")
    expect(group.reload).to be_pending
    expect(group.chat_pending_actions.reload).to all(be_pending)
  end
end
