require "rails_helper"

RSpec.describe Mcp::Tools::ScheduleWakeupTool do
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

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(arguments)
    jsonrpc(server, "tools/call", params: { name: "schedule_wakeup", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def response_text(response)
    response.fetch(:result).fetch(:content).first.fetch(:text)
  end

  before do
    clear_enqueued_jobs
  end

  it "creates a relative wakeup for the current chat session and user" do
    travel_to Time.zone.parse("2026-06-24 12:00:00 UTC") do
      response = call_tool(prompt: "Check JOB-123 and reschedule if needed.", delay_minutes: 30)

      wakeup = ChatWakeup.sole
      expect(response[:result][:isError]).to be_falsey
      expect(response_payload(response)).to include(
        wakeup_id: wakeup.id,
        fire_at: "2026-06-24T12:30:00Z",
        message: "Wakeup scheduled for 2026-06-24T12:30:00Z"
      )
      expect(wakeup).to have_attributes(
        chat_session: chat_session,
        user: user,
        prompt: "Check JOB-123 and reschedule if needed.",
        state: "pending"
      )
      expect(wakeup.fire_at).to eq(Time.zone.parse("2026-06-24 12:30:00 UTC"))
      expect(ChatWakeupFireJob).to have_been_enqueued.with(wakeup.id).at(Time.zone.parse("2026-06-24 12:30:00 UTC"))
    end
  end

  it "creates a wakeup for an absolute fire_at timestamp" do
    travel_to Time.zone.parse("2026-06-24 12:00:00 UTC") do
      response = call_tool(prompt: "Check JOB-456 and report back.", fire_at: "2026-07-15T09:30:00Z")

      wakeup = ChatWakeup.sole
      expect(response[:result][:isError]).to be_falsey
      expect(response_payload(response)).to include(
        wakeup_id: wakeup.id,
        fire_at: "2026-07-15T09:30:00Z",
        message: "Wakeup scheduled for 2026-07-15T09:30:00Z"
      )
      expect(wakeup).to have_attributes(
        chat_session: chat_session,
        user: user,
        prompt: "Check JOB-456 and report back.",
        state: "pending"
      )
      expect(wakeup.fire_at).to eq(Time.zone.parse("2026-07-15 09:30:00 UTC"))
      expect(ChatWakeupFireJob).to have_been_enqueued.with(wakeup.id).at(Time.zone.parse("2026-07-15 09:30:00 UTC"))
    end
  end

  it "rejects blank prompts" do
    response = call_tool(prompt: "   ", delay_minutes: 30)

    expect(response[:result][:isError]).to be(true)
    expect(response_text(response)).to match(/prompt is required/)
    expect(ChatWakeup.count).to eq(0)
  end

  it "rejects calls without a scheduling input" do
    response = call_tool(prompt: "Check later.")

    expect(response[:result][:isError]).to be(true)
    expect(response_text(response)).to match(/provide exactly one of delay_minutes or fire_at/)
    expect(ChatWakeup.count).to eq(0)
  end

  it "rejects calls with both delay_minutes and fire_at" do
    response = call_tool(
      prompt: "Check later.",
      delay_minutes: 30,
      fire_at: 2.days.from_now.utc.iso8601
    )

    expect(response[:result][:isError]).to be(true)
    expect(response_text(response)).to match(/provide exactly one of delay_minutes or fire_at/)
    expect(ChatWakeup.count).to eq(0)
  end

  it "rejects delay_minutes below the allowed range" do
    response = call_tool(prompt: "Check later.", delay_minutes: 0)

    expect(response[:result][:isError]).to be(true)
    expect(response_text(response)).to match(/between 1 and 1440/)
    expect(ChatWakeup.count).to eq(0)
  end

  it "rejects delay_minutes above the allowed range" do
    response = call_tool(prompt: "Check later.", delay_minutes: 1441)

    expect(response[:result][:isError]).to be(true)
    expect(response_text(response)).to match(/between 1 and 1440/)
    expect(ChatWakeup.count).to eq(0)
  end

  it "rejects past fire_at timestamps" do
    travel_to Time.zone.parse("2026-06-24 12:00:00 UTC") do
      response = call_tool(prompt: "Check later.", fire_at: "2026-06-24T11:59:00Z")

      expect(response[:result][:isError]).to be(true)
      expect(response_text(response)).to match(/fire_at must be in the future/)
      expect(ChatWakeup.count).to eq(0)
    end
  end

  it "rejects malformed fire_at timestamps" do
    response = call_tool(prompt: "Check later.", fire_at: "October 13 at 9")

    expect(response[:result][:isError]).to be(true)
    expect(response_text(response)).to match(/fire_at must be an ISO 8601 timestamp/)
    expect(ChatWakeup.count).to eq(0)
  end
end
