require "rails_helper"
require Rails.root.join("db/migrate/20260827135000_expire_malformed_chat_agent_questions")

RSpec.describe ExpireMalformedChatAgentQuestions, :ci_only do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "expires active rows that lost their questions payload" do
    question = chat_session.agent_questions.build(questions: nil, asked_at: Time.current)
    question.save!(validate: false)

    described_class.new.up

    expect(question.reload.expired_at).to be_present
  end

  it "leaves valid active rows alone" do
    question = chat_session.agent_questions.create!(
      questions: [ { "question" => "Deploy?", "options" => nil, "multiple" => false } ],
      asked_at: Time.current
    )

    described_class.new.up

    expect(question.reload.expired_at).to be_nil
  end
end
