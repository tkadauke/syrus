require "rails_helper"

RSpec.describe Mcp::Tools::AskUserQuestionTool do
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

  it "creates a question and returns immediately with question_id" do
    response = call_tool(question: "Which implementation path?", options: [ "Fast", "Careful" ])

    question = chat_session.agent_questions.sole
    expect(question.question).to eq("Which implementation path?")
    expect(question.options).to eq([ "Fast", "Careful" ])
    expect(question.answer).to be_nil
    expect(question.answered_at).to be_nil
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(question_id: question.id)
  end

  it "rejects invalid options" do
    response = call_tool(question: "Pick one", options: [ "Yes", "" ])

    expect(response[:result][:isError]).to eq(true)
    expect(response[:result][:content].first[:text]).to match(/options/)
    expect(chat_session.agent_questions).to be_empty
  end
end
