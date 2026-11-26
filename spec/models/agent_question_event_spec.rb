require "rails_helper"

RSpec.describe AgentQuestionEvent do
  it "notifies the Job owner when a workflow question is asked" do
    run = Factories.job.initial_run

    question = nil
    expect {
      question = AgentQuestion.create!(run:, questions: [ { "question" => "Path?", "options" => nil, "multiple" => false } ], asked_at: Time.current)
    }.to change { run.user.notifications.where(kind: "agent_question_asked").count }.by(1)

    notification = run.user.notifications.where(kind: "agent_question_asked").last
    expect(notification).to have_attributes(job: run.job, target_path: "/jobs/#{run.job.id}#agent-question-#{question.id}")
  end

  it "records asked, answered, withdrawn, and timed-out domain events" do
    run = Factories.job.initial_run
    asked = AgentQuestion.create!(run: run, questions: [ { "question" => "Path?", "options" => nil, "multiple" => false } ], defaults: [ "Careful" ], asked_at: Time.current)
    allow(AgentQuestions::Resume).to receive(:call)
    asked.answer!(answers: [ "Fast" ], answered_by: run.user, source: "web")

    withdrawn = AgentQuestion.create!(run: run, questions: [ { "question" => "Scope?", "options" => nil, "multiple" => false } ], defaults: [ "Small" ], asked_at: Time.current)
    withdrawn.withdraw!(source: "operator")

    timed_out = AgentQuestion.create!(run: run, questions: [ { "question" => "Wait?", "options" => nil, "multiple" => false } ], defaults: [ "No" ], asked_at: Time.current)
    timed_out.update!(timed_out_at: Time.current)

    expect(asked.events.pluck(:event_type, :source)).to eq([ [ "asked", "workflow" ], [ "answered", "web" ] ])
    expect(withdrawn.events.pluck(:event_type)).to eq(%w[asked withdrawn])
    expect(timed_out.events.pluck(:event_type)).to eq(%w[asked timed_out])
  end
end
