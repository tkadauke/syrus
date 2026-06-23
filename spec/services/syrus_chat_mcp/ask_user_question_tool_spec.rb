require "rails_helper"

RSpec.describe SyrusChatMcp::AskUserQuestionTool do
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
    jsonrpc(server, "tools/call", params: { name: "ask_user_question", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "creates a question, waits for an answer, and returns it" do
    allow(described_class).to receive(:sleep) do
      ChatAgentQuestion.sole.answer!("Careful")
    end

    response = call_tool(question: "Which implementation path?", options: [ "Fast", "Careful" ])

    question = chat_session.agent_questions.sole
    expect(question.question).to eq("Which implementation path?")
    expect(question.options).to eq([ "Fast", "Careful" ])
    expect(question.answer).to eq("Careful")
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to eq(answer: "Careful")
  end

  it "expires the question and returns a tool error on timeout" do
    stub_const("#{described_class}::ASK_TIMEOUT_SECONDS", 0)

    response = call_tool(question: "Are you still there?")

    question = chat_session.agent_questions.sole
    expect(question.expired_at).to be_present
    expect(response[:result][:isError]).to eq(true)
    expect(response[:result][:content].first[:text]).to match(/Timed out/)
  end

  it "rejects invalid options" do
    response = call_tool(question: "Pick one", options: [ "Yes", "" ])

    expect(response[:result][:isError]).to eq(true)
    expect(response[:result][:content].first[:text]).to match(/options/)
    expect(chat_session.agent_questions).to be_empty
  end
end
