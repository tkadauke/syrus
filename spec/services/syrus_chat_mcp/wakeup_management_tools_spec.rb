require "rails_helper"

RSpec.describe "Mcp::Tools wakeup management tools" do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }
  let(:other_session) { ChatSession.create!(user: user) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::ListWakeupsTool,
        Mcp::Tools::CancelWakeupTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(name, arguments = {})
    jsonrpc(server, "tools/call", params: { name: name, arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def create_wakeup(chat_session:, fire_at:, prompt: "Check JOB-123 and report back.", state: "pending")
    ChatWakeup.create!(
      chat_session: chat_session,
      user: chat_session.user,
      prompt: prompt,
      fire_at: fire_at,
      state: state
    )
  end

  before do
    clear_enqueued_jobs
  end

  it "lists only pending wakeups for the current session ordered by fire_at" do
    travel_to Time.zone.parse("2026-06-24 12:00:00 UTC") do
      later_prompt = "Check J1111 state. If implemented, approve it. " + ("x" * 140)
      later = create_wakeup(chat_session: chat_session, fire_at: 25.minutes.from_now, prompt: later_prompt)
      earlier = create_wakeup(chat_session: chat_session, fire_at: 12.minutes.from_now, prompt: "Check the first thing.")
      create_wakeup(chat_session: chat_session, fire_at: 8.minutes.from_now, state: "fired")
      create_wakeup(chat_session: chat_session, fire_at: 9.minutes.from_now, state: "cancelled")
      create_wakeup(chat_session: other_session, fire_at: 10.minutes.from_now)

      response = call_tool("list_wakeups")

      expect(response[:result][:isError]).to be_falsey
      expect(response_payload(response)).to eq(
        wakeups: [
          {
            id: earlier.id,
            fire_at: "2026-06-24T12:12:00Z",
            delay_remaining_minutes: 12,
            prompt_preview: "Check the first thing."
          },
          {
            id: later.id,
            fire_at: "2026-06-24T12:25:00Z",
            delay_remaining_minutes: 25,
            prompt_preview: later_prompt.each_char.first(120).join
          }
        ]
      )
    end
  end

  it "cancels a pending wakeup and the fire job exits cleanly" do
    wakeup = create_wakeup(chat_session: chat_session, fire_at: 5.minutes.from_now)

    response = call_tool("cancel_wakeup", wakeup_id: wakeup.id)

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to eq(cancelled: true, wakeup_id: wakeup.id)
    expect(wakeup.reload).to be_cancelled
    expect(ChatSession::WakeupTurn).not_to receive(:new)

    ChatWakeupFireJob.perform_now(wakeup.id)

    expect(wakeup.reload).to be_cancelled
  end

  it "returns invalid for a wakeup in another session" do
    wakeup = create_wakeup(chat_session: other_session, fire_at: 5.minutes.from_now)

    response = call_tool("cancel_wakeup", wakeup_id: wakeup.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/wakeup not found or not pending/)
    expect(wakeup.reload).to be_pending
  end

  it "returns invalid for a non-pending wakeup" do
    wakeup = create_wakeup(chat_session: chat_session, fire_at: 5.minutes.from_now, state: "fired")

    response = call_tool("cancel_wakeup", wakeup_id: wakeup.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/wakeup not found or not pending/)
    expect(wakeup.reload).to be_fired
  end
end
