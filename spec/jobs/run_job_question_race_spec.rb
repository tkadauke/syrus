require "rails_helper"

RSpec.describe RunJob do
  it "does not strand an answer that arrives before the step finishes parking" do
    run = Factories.job.initial_run
    run.update!(state: "running")
    run.step.update!(state: "running")
    question = AgentQuestion.create!(
      run: run, questions: [ { "question" => "Path?", "options" => nil, "multiple" => false } ],
      defaults: [ "Careful" ], answers: [ "Fast" ], asked_at: Time.current,
      answered_at: Time.current, answer_source: "web"
    )
    allow_any_instance_of(Run).to receive(:reenqueue!)
    job = described_class.new
    job.instance_variable_set(:@run, run)
    job.instance_variable_set(:@step, run.step)
    allow(job).to receive(:log)

    job.send(:park_for_operator_answer!)

    expect(question.reload).not_to be_active
    expect(run.reload.state).to eq("queued")
    expect(run.step.reload.state).to eq("running")
  end
end
