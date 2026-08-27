require "rails_helper"

RSpec.describe ChatAgentQuestion do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def build_question(chat_session, questions)
    chat_session.agent_questions.create!(questions: questions, asked_at: Time.current)
  end

  it "answers a single active question once" do
    question = build_question(chat_session, [ { "question" => "Deploy now?", "options" => [ "Yes", "No" ], "multiple" => false } ])

    expect(question.answer_and_record!([ "Yes" ])).to eq(true)
    expect(question.reload.answers).to eq([ "Yes" ])
    expect(question.answered_at).to be_present
    expect(question.answer_and_record!([ "No" ])).to eq(false)
    expect(question.reload.answers).to eq([ "Yes" ])
  end

  it "answers a batch of questions atomically and records one combined chat message" do
    question = build_question(chat_session, [
      { "question" => "Which path?", "options" => [ "Fast", "Careful" ], "multiple" => false },
      { "question" => "Which environments?", "options" => [ "Staging", "Production" ], "multiple" => true },
      { "question" => "Anything else?", "options" => nil, "multiple" => false }
    ])

    expect {
      expect(question.answer_and_record!([ "Careful", [ "Staging", "Production" ], "Nope" ], sender_user: user)).to eq(true)
    }.to have_enqueued_job(ChatTurnJob).with(chat_session.id, kind_of(Integer))

    expect(question.reload.answers).to eq([ "Careful", [ "Staging", "Production" ], "Nope" ])
    message = chat_session.messages.sole
    expect(message.role).to eq("user")
    expect(message.sender_user_id).to eq(user.id)
    expect(message.content["text"]).to eq(<<~TEXT.strip)
      Q1: Which path?
      A1: Careful

      Q2: Which environments?
      A2: Staging, Production

      Q3: Anything else?
      A3: Nope
    TEXT
    expect(chat_session.reload.last_message_at).to be_present
  end

  it "rejects an answers array with the wrong length" do
    question = build_question(chat_session, [ { "question" => "Deploy now?", "options" => nil, "multiple" => false } ])

    expect(question.answer_and_record!([ "Yes", "extra" ])).to eq(false)
    expect(question.reload.answers).to be_nil
    expect(question.reload.answered_at).to be_nil
  end

  it "rejects answers for malformed persisted questions without raising" do
    question = chat_session.agent_questions.build(questions: nil, asked_at: Time.current)
    question.save!(validate: false)

    expect(question.answer_and_record!([ "Yes" ])).to eq(false)
    expect(question.reload.answers).to be_nil
    expect(question.reload.answered_at).to be_nil
  end

  it "returns an empty payload for malformed persisted questions" do
    question = chat_session.agent_questions.build(questions: nil, asked_at: Time.current)
    question.save!(validate: false)

    expect(question.questions_payload).to eq([])
  end

  it "rejects a blank answer for a single-select/free-text question" do
    question = build_question(chat_session, [ { "question" => "Deploy now?", "options" => nil, "multiple" => false } ])

    expect(question.answer_and_record!([ "  " ])).to eq(false)
    expect(question.reload.answered_at).to be_nil
  end

  it "rejects a non-array answer for a multi-select question" do
    question = build_question(chat_session, [ { "question" => "Which environments?", "options" => [ "Staging", "Production" ], "multiple" => true } ])

    expect(question.answer_and_record!([ "Staging" ])).to eq(false)
    expect(question.reload.answered_at).to be_nil
  end

  it "rejects an empty array answer for a multi-select question" do
    question = build_question(chat_session, [ { "question" => "Which environments?", "options" => [ "Staging", "Production" ], "multiple" => true } ])

    expect(question.answer_and_record!([ [] ])).to eq(false)
    expect(question.reload.answered_at).to be_nil
  end

  it "does not enqueue a ChatTurnJob when an agent turn is already running" do
    SpawnedProcess.create!(
      kind: "agent",
      command: "claude --print",
      workdir: chat_session.workspace_root.to_s,
      hostname: "worker-1",
      started_at: Time.current,
      pid: 1234
    )
    question = build_question(chat_session, [ { "question" => "Deploy now?", "options" => nil, "multiple" => false } ])

    expect { question.answer_and_record!([ "Yes" ]) }.not_to have_enqueued_job(ChatTurnJob)
    expect(question.reload.answers).to eq([ "Yes" ])
  end

  it "expires an unanswered question" do
    question = build_question(chat_session, [ { "question" => "Need a fallback?", "options" => nil, "multiple" => false } ])

    expect(question.expire!).to eq(true)
    expect(question.reload.expired_at).to be_present
    expect(question.answer_and_record!([ "Fallback" ])).to eq(false)
  end

  it "expires malformed persisted questions without revalidating their payload" do
    question = chat_session.agent_questions.build(questions: nil, asked_at: Time.current)
    question.save!(validate: false)

    expect(question.expire!).to eq(true)
    expect(question.reload.expired_at).to be_present
  end

  it "validates 1 to 4 questions" do
    question = chat_session.agent_questions.build(questions: [], asked_at: Time.current)

    expect(question).not_to be_valid
    expect(question.errors[:questions]).to include("must be an array of 1 to 4 questions")

    question.questions = Array.new(5) { |i| { "question" => "Q#{i}", "options" => nil, "multiple" => false } }
    expect(question).not_to be_valid
    expect(question.errors[:questions]).to include("must be an array of 1 to 4 questions")
  end

  it "validates options as non-empty strings" do
    question = chat_session.agent_questions.build(
      questions: [ { "question" => "Pick one", "options" => [ "Yes", "" ], "multiple" => false } ],
      asked_at: Time.current
    )

    expect(question).not_to be_valid
    expect(question.errors[:questions]).to include("options must be an array of non-empty strings")
  end

  it "validates multiple:true requires non-empty options" do
    question = chat_session.agent_questions.build(
      questions: [ { "question" => "Pick any", "options" => nil, "multiple" => true } ],
      asked_at: Time.current
    )

    expect(question).not_to be_valid
    expect(question.errors[:questions]).to include("multiple-select questions require options")
  end
end
