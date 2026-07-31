require "rails_helper"

RSpec.describe ChatAgentQuestion do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  it "answers an active question once" do
    question = chat_session.agent_questions.create!(question: "Deploy now?", options: [ "Yes", "No" ], asked_at: Time.current)

    expect(question.answer!("Yes")).to eq(true)
    expect(question.reload.answer).to eq("Yes")
    expect(question.answered_at).to be_present
    expect(question.answer!("No")).to eq(false)
    expect(question.reload.answer).to eq("Yes")
  end

  it "records an answer as a user chat message and enqueues a new turn" do
    question = chat_session.agent_questions.create!(question: "Deploy now?", options: [ "Yes", "No" ], asked_at: Time.current)

    expect {
      expect(question.answer_and_record!("No")).to eq(true)
    }.to have_enqueued_job(ChatTurnJob).with(chat_session.id, kind_of(Integer))
    expect(question.reload.answer).to eq("No")
    expect(chat_session.messages.sole).to have_attributes(
      role: "user",
      content: { "text" => "No" }
    )
    expect(chat_session.reload.last_message_at).to be_present
    jobs = ActiveJob::Base.queue_adapter.enqueued_jobs
    expect(jobs.any? { |job| job.fetch(:job) == ChatTurnJob && job.fetch(:args) == [ chat_session.id, chat_session.messages.sole.id ] }).to eq(true)
  end

  it "does not enqueue a ChatTurnJob when an agent turn is already running" do
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat_session.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current
    )
    question = chat_session.agent_questions.create!(question: "Deploy now?", asked_at: Time.current)

    expect { question.answer_and_record!("Yes") }.not_to have_enqueued_job(ChatTurnJob)
    expect(question.reload.answer).to eq("Yes")
  end

  it "expires an unanswered question" do
    question = chat_session.agent_questions.create!(question: "Need a fallback?", asked_at: Time.current)

    expect(question.expire!).to eq(true)
    expect(question.reload.expired_at).to be_present
    expect(question.answer!("Fallback")).to eq(false)
  end

  it "validates options as non-empty strings" do
    question = chat_session.agent_questions.build(question: "Pick one", options: [ "Yes", "" ], asked_at: Time.current)

    expect(question).not_to be_valid
    expect(question.errors[:options]).to include("must be an array of non-empty strings")
  end
end
