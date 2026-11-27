require "rails_helper"

RSpec.describe "workflow question chat tools", :full_chat_access do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user) }
  let(:repository) { Factories.repository(user: user) }
  let(:run) { Factories.job(user: user, repository: repository).initial_run }
  let!(:question) do
    AgentQuestion.create!(
      run: run,
      questions: [ { "question" => "Which path?", "options" => [ "Fast", "Careful" ], "multiple" => false } ],
      defaults: [ "Careful" ], asked_at: Time.current
    )
  end

  it "lists and answers an owned open question" do
    listed = Mcp::Tools::ListOpenAgentQuestionsTool.call(server_context: { chat_session: chat })
    expect(listed.content.first.fetch(:text)).to include("Which path?")
    allow(AgentQuestions::Resume).to receive(:call)

    answered = Mcp::Tools::AnswerAgentQuestionTool.call(
      question_id: question.id, answers: [ "Fast" ], server_context: { chat_session: chat }
    )

    expect(answered).not_to be_error
    expect(question.reload).to have_attributes(answers: [ "Fast" ], answered_by: user, answer_source: "chat_tool")
  end

  it "does not expose another user's question" do
    other_chat = ChatSession.create!(user: Factories.user)

    listed = Mcp::Tools::ListOpenAgentQuestionsTool.call(server_context: { chat_session: other_chat })
    answered = Mcp::Tools::AnswerAgentQuestionTool.call(
      question_id: question.id, answers: [ "Fast" ], server_context: { chat_session: other_chat }
    )

    expect(listed.content.first.fetch(:text)).not_to include("Which path?")
    expect(answered).to be_error
  end

  it "does not allow a read-only repository member to answer, but allows a writer" do
    reader = Factories.user
    writer = Factories.user
    repository.repository_memberships.create!(user: reader, role: "read")
    repository.repository_memberships.create!(user: writer, role: "write")

    denied = Mcp::Tools::AnswerAgentQuestionTool.call(
      question_id: question.id, answers: [ "Fast" ], server_context: { chat_session: ChatSession.create!(user: reader) }
    )
    allowed = Mcp::Tools::AnswerAgentQuestionTool.call(
      question_id: question.id, answers: [ "Careful" ], server_context: { chat_session: ChatSession.create!(user: writer) }
    )

    expect(denied).to be_error
    expect(allowed).not_to be_error
    expect(question.reload).to have_attributes(answers: [ "Careful" ], answered_by: writer)
  end

  it "preloads runs and jobs for a batch instead of querying per question" do
    second_run = Factories.job(user: user, repository: repository, issue_number: 99).initial_run
    AgentQuestion.create!(
      run: second_run,
      questions: [ { "question" => "Second?", "options" => nil, "multiple" => false } ],
      asked_at: Time.current
    )
    association_queries = []
    subscriber = ->(*, payload) do
      sql = payload[:sql].to_s
      association_queries << sql if sql.match?(/FROM ["`]?(runs|jobs)["`]?/i)
    end

    ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") do
      Mcp::Tools::ListOpenAgentQuestionsTool.call(server_context: { chat_session: chat })
    end

    expect(association_queries.grep(/FROM ["`]?runs["`]?/i).size).to eq(1)
    # One visibility query plus one preload query; neither grows with the batch.
    expect(association_queries.grep(/FROM ["`]?jobs["`]?/i).size).to be <= 2
  end
end
