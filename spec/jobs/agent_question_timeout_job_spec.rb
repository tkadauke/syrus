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
end
