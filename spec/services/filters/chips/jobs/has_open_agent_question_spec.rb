require "rails_helper"

RSpec.describe Filters::Chips::Jobs::HasOpenAgentQuestion do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let!(:waiting) { Factories.job(user:, repository:) }
  let!(:ordinary) { Factories.job(user:, repository:, issue_number: 2) }

  before do
    AgentQuestion.create!(run: waiting.initial_run, asked_at: Time.current,
      questions: [ { "question" => "Ship it?", "options" => nil, "multiple" => false } ])
  end

  def filtered(op)
    Filters::Compiler.call(Filters::Ast.parse("field" => "has_open_agent_question", "op" => op),
      scope: Job.where(repository:), user:, subject: :job)
  end

  it "matches only Jobs with an active workflow question" do
    expect(filtered("is_true")).to contain_exactly(waiting)
    expect(filtered("is_false")).to contain_exactly(ordinary)
  end
end
