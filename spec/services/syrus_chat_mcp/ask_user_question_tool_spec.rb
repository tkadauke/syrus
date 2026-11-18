require "rails_helper"

RSpec.describe Mcp::Tools::AskUserQuestionTool, :full_chat_access do
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

  it "creates a single question and returns immediately with question_id" do
    response = call_tool(questions: [ { question: "Which implementation path?", options: [ "Fast", "Careful" ] } ])

    question = chat_session.agent_questions.sole
    expect(question.questions).to eq([ { "question" => "Which implementation path?", "options" => [ "Fast", "Careful" ], "multiple" => false } ])
    expect(question.answers).to be_nil
    expect(question.answered_at).to be_nil
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(question_id: question.id)
  end

  it "records a delegated question in the owner chat and resumes the execution chat when answered" do
    owner_chat = ChatSession.create!(user: user, repository: repository)
    chat_session.define_singleton_method(:owner_facing_chat_session) { owner_chat }
    response = call_tool(questions: [ { question: "Which path?" } ])
    question = owner_chat.agent_questions.sole

    expect(response_payload(response)).to include(question_id: question.id)
    expect(question.response_chat_session).to eq(chat_session)
    expect { question.answer_and_record!([ "Careful" ], sender_user: user) }
      .to have_enqueued_job(ChatTurnJob).with(chat_session.id, kind_of(Integer))
    expect(chat_session.messages.last.content).to include("source" => "agent_question_answer")
  end

  it "normalizes literal backslash-n sequences into real line breaks" do
    response = call_tool(questions: [ { question: "Two scoping questions:\\n1. Scope to X?\\n2. Name it Y?" } ])

    question = chat_session.agent_questions.sole
    expect(question.questions).to eq([
      { "question" => "Two scoping questions:\n1. Scope to X?\n2. Name it Y?", "options" => nil, "multiple" => false }
    ])
    expect(response[:result][:isError]).to be_falsey
  end

  it "batches up to 4 questions in one call, each independently shaped" do
    response = call_tool(questions: [
      { question: "Which implementation path?", options: [ "Fast", "Careful" ] },
      { question: "Which environments should this ship to?", options: [ "Staging", "Production" ], multiple: true },
      { question: "Anything else we should know?" }
    ])

    question = chat_session.agent_questions.sole
    expect(question.questions).to eq([
      { "question" => "Which implementation path?", "options" => [ "Fast", "Careful" ], "multiple" => false },
      { "question" => "Which environments should this ship to?", "options" => [ "Staging", "Production" ], "multiple" => true },
      { "question" => "Anything else we should know?", "options" => nil, "multiple" => false }
    ])
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(question_id: question.id)
  end

  it "rejects more than 4 questions" do
    response = call_tool(questions: Array.new(5) { |i| { question: "Question #{i}" } })

    expect(response[:result][:isError]).to eq(true)
    expect(chat_session.agent_questions).to be_empty
  end

  it "rejects an empty questions array" do
    response = call_tool(questions: [])

    expect(response[:result][:isError]).to eq(true)
    expect(chat_session.agent_questions).to be_empty
  end

  it "rejects invalid options" do
    response = call_tool(questions: [ { question: "Pick one", options: [ "Yes", "" ] } ])

    expect(response[:result][:isError]).to eq(true)
    expect(response[:result][:content].first[:text]).to match(/options/)
    expect(chat_session.agent_questions).to be_empty
  end

  it "rejects multiple:true without options" do
    response = call_tool(questions: [ { question: "Pick any", multiple: true } ])

    expect(response[:result][:isError]).to eq(true)
    expect(response[:result][:content].first[:text]).to match(/multiple-select/)
    expect(chat_session.agent_questions).to be_empty
  end

  it "rejects a blank question in the batch" do
    response = call_tool(questions: [ { question: "Fine" }, { question: "  " } ])

    expect(response[:result][:isError]).to eq(true)
    expect(chat_session.agent_questions).to be_empty
  end
end
