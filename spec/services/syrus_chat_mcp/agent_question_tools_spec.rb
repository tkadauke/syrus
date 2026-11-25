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
end
