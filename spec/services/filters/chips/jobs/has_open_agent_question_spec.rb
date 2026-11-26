require "rails_helper"

RSpec.describe Filters::Chips::Jobs::HasOpenAgentQuestion do
  it "selects only Jobs with active workflow questions" do
    waiting = Factories.job
    answered = Factories.job
    other = Factories.job
    AgentQuestion.create!(run: waiting.initial_run, asked_at: Time.current,
      questions: [ { "question" => "Path?", "options" => nil, "multiple" => false } ])
    closed = AgentQuestion.create!(run: answered.initial_run, asked_at: Time.current,
      questions: [ { "question" => "Scope?", "options" => nil, "multiple" => false } ])
    allow(AgentQuestions::Resume).to receive(:call)
    closed.answer!(answers: [ "Small" ], answered_by: answered.user, source: "web")

    truthy = described_class.new(scope: Job.where(id: [ waiting.id, answered.id, other.id ]), op: :is_true, value: nil)
    falsy = described_class.new(scope: Job.where(id: [ waiting.id, answered.id, other.id ]), op: :is_false, value: nil)

    expect(truthy.apply).to contain_exactly(waiting)
    expect(falsy.apply).to contain_exactly(answered, other)
  end
end
