require "rails_helper"

RSpec.describe AgentQuestionTimeoutJob do
  it "answers an expired workflow question with its defaults and resumes it" do
    run = Factories.job.initial_run
    run.update!(state: "awaiting_answer")
    run.step.update!(state: "awaiting_answer")
    question = AgentQuestion.create!(
      run: run,
      questions: [ { "question" => "Which path?", "options" => nil, "multiple" => false } ],
      defaults: [ "Careful" ], asked_at: 2.hours.ago, times_out_at: 1.hour.ago
    )
    allow_any_instance_of(Run).to receive(:reenqueue!)

    described_class.perform_now(question.id)

    expect(question.reload).to have_attributes(answers: [ "Careful" ], answer_source: "timeout")
    expect(question.timed_out_at).to be_present
    expect(run.reload.state).to eq("queued")
  end

  it "does not mark or emit a timeout after an operator answer wins" do
    run = Factories.job.initial_run
    question = AgentQuestion.create!(
      run: run,
      questions: [ { "question" => "Which path?", "options" => nil, "multiple" => false } ],
      defaults: [ "Careful" ], asked_at: 2.hours.ago, times_out_at: 1.hour.ago
    )
    question.answer!(answers: [ "Fast" ], answered_by: run.user, source: "web")

    described_class.perform_now(question.id)

    expect(question.reload).to have_attributes(answers: [ "Fast" ], timed_out_at: nil, answer_source: "web")
    expect(question.events.where(event_type: "timed_out")).to be_empty
  end
end
