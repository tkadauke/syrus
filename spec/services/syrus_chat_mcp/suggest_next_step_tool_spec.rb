require "rails_helper"

RSpec.describe SyrusChatMcp::SuggestNextStepTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

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
    jsonrpc(server, "tools/call", params: { name: "suggest_next_step", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "stores the suggestion on the chat session" do
    response = call_tool(text: "Create an Epic from these findings")

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(
      session_id: chat_session.id,
      suggested_next_step: "Create an Epic from these findings"
    )
    expect(chat_session.reload.suggested_next_step).to eq("Create an Epic from these findings")
  end

  it "trims the provided text" do
    call_tool(text: "  File the follow-up Job  ")

    expect(chat_session.reload.suggested_next_step).to eq("File the follow-up Job")
  end

  it "clamps suggestions to the byte limit without splitting multibyte characters" do
    long = "é" * 300

    response = call_tool(text: long)

    stored = chat_session.reload.suggested_next_step
    expect(response[:result][:isError]).to be_falsey
    expect(stored.bytesize).to be <= ChatSession::SUGGESTED_NEXT_STEP_MAX_BYTES
    expect(stored).to eq("é" * 100)
    expect(stored).to be_valid_encoding
  end

  it "advertises the byte-based truncation honestly in the input schema" do
    response = jsonrpc(server, "tools/list")
    tool = response.dig(:result, :tools).find { |entry| entry[:name] == "suggest_next_step" }
    description = tool.dig(:inputSchema, :properties, :text, :description)

    # The clamp is bytes (record_suggested_next_step! uses
    # safe_byteslice), so the copy must say bytes — with a
    # plain-language hint — not "characters".
    expect(description).to include("#{ChatSession::SUGGESTED_NEXT_STEP_MAX_BYTES} bytes")
    expect(description).to include("emoji")
    expect(description).not_to match(/up to \d+ characters/)
  end

  it "rejects blank text" do
    response = call_tool(text: "   ")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/text is required/)
    expect(chat_session.reload.suggested_next_step).to be_nil
  end

  it "broadcasts a compact suggestion app event" do
    events = []
    allow(AppEvents).to receive(:broadcast) do |**kwargs|
      events << kwargs
    end

    call_tool(text: "Ship it")

    suggestion_event = events.find { |event| event[:changed] == [ "suggestion" ] }
    expect(suggestion_event).to include(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id
    )
    expect(suggestion_event[:payload]).to eq(
      action: "update_suggestion",
      suggested_next_step: "Ship it"
    )
  end
end
