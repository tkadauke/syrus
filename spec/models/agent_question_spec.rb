require "rails_helper"

RSpec.describe AgentQuestion do
  let(:user) { Factories.user }
  let(:run) { Factories.job(user: user).initial_run }

  def question
    described_class.create!(
      run: run,
      questions: [
        { "question" => "Which path?", "options" => [ "Fast", "Careful" ], "multiple" => false },
        { "question" => "Targets?", "options" => [ "Web", "CLI" ], "multiple" => true },
        { "question" => "Notes?", "options" => nil, "multiple" => false }
      ],
      defaults: [ "Careful", [ "Web" ], "None" ],
      asked_at: Time.current
    )
  end

  it "accepts choice, multi-select, and free-text answers, with first answer winning" do
    record = question
    allow(AgentQuestions::Resume).to receive(:call)

    expect(record.answer!(answers: [ "A custom choice", [ "Web", "CLI" ], "Keep compatibility" ], answered_by: user, source: "web")).to eq(true)
    expect(record.answer!(answers: [ "Fast", [ "CLI" ], "Overwrite" ], answered_by: user, source: "mobile")).to eq(false)
    expect(record.reload).to have_attributes(
      answers: [ "A custom choice", [ "Web", "CLI" ], "Keep compatibility" ],
      answered_by: user,
      answer_source: "web"
    )
  end

  it "resumes an awaiting run and step in the recorded provider session" do
    record = question
    run.update!(state: "awaiting_answer")
    run.step.update!(state: "awaiting_answer")
    run.create_provider_session!(session_id: "provider-session", transcript_jsonl: "")
    allow(run).to receive(:reenqueue!)

    expect(record.answer!(answers: [ "Careful", [ "Web" ], "None" ], answered_by: user, source: "chat_tool")).to eq(true)

    expect(run.reload).to have_attributes(state: "queued", parent_session_id: "provider-session")
    expect(run.step.reload.state).to eq("running")
  end

  it "falls back to a fresh prompt when no provider session is available" do
    record = question
    run.update!(state: "awaiting_answer")
    run.step.update!(state: "awaiting_answer")
    allow(run).to receive(:reenqueue!)

    record.answer!(answers: [ "Careful", [ "Web" ], "Compatibility" ], answered_by: user, source: "web")

    expect(run.reload.prompt).to include("The operator answered", "A1: Careful", "A3: Compatibility")
    expect(run.parent_session_id).to be_nil
  end

  it "keeps awaiting-answer work out of retry and stale-run candidates" do
    run.workflow.update!(state: "running")
    run.update!(state: "awaiting_answer", started_at: 2.days.ago, last_heartbeat_at: 2.days.ago)
    run.step.update!(state: "awaiting_answer")

    expect(Run.active).not_to include(run)
    expect(Run.stale).not_to include(run)
    expect(run.step.awaiting_run?).to eq(false)
    expect(run.workflow).to be_running
  end
end
