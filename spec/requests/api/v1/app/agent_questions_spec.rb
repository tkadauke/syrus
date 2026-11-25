require "rails_helper"

RSpec.describe "workflow agent questions API", type: :request do
  def parse_body = JSON.parse(response.body)
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job(repository:, user:) }
  let(:run) { job.initial_run }

  before { sign_in_as(user) }

  it "lists visible open workflow questions with their shared answer path" do
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Ship it?", "options" => [ "Yes", "No" ], "multiple" => false } ])

    get "/api/v1/app/agent_questions"

    expect(response).to have_http_status(:ok)
    expect(parse_body.fetch("questions")).to contain_exactly(include(
      "id" => question.id,
      "job_id" => job.id,
      "app_answer_path" => "/api/v1/app/agent_questions/#{question.id}/answer"
    ))
  end

  it "answers through AgentQuestion and resumes its workflow" do
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Ship it?", "options" => [ "Yes", "No" ], "multiple" => false } ])
    allow(AgentQuestions::Resume).to receive(:call)

    post "/api/v1/app/agent_questions/#{question.id}/answer", params: { answers: [ "Yes" ] }

    expect(response).to have_http_status(:ok)
    expect(question.reload.answers).to eq([ "Yes" ])
    expect(AgentQuestions::Resume).to have_received(:call).with(question)
  end

  it "normalizes nested multi-select answers from form parameters" do
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Choose paths", "options" => [ "Fast", "Safe", "Custom" ], "multiple" => true } ])
    allow(AgentQuestions::Resume).to receive(:call)

    post "/api/v1/app/agent_questions/#{question.id}/answer", params: { answers: { "0" => [ "Fast", "Safe" ] } }

    expect(response).to have_http_status(:ok)
    expect(question.reload.answers).to eq([ [ "Fast", "Safe" ] ])
  end

  it "does not expose questions on jobs the user cannot see" do
    other = Factories.user
    other_repository = Factories.repository(user: other)
    other_job = Factories.job(repository: other_repository, user: other)
    AgentQuestion.create!(run: other_job.initial_run, asked_at: Time.current, questions: [ { "question" => "Secret?", "options" => nil, "multiple" => false } ])

    get "/api/v1/app/agent_questions"
    expect(parse_body.fetch("questions")).to be_empty
  end

  it "files a repair Job through the Job mutation gate" do
    post "/api/v1/app/jobs/#{job.id}/file_question_fix"

    expect(response).to have_http_status(:ok)
    dependency = job.dependencies.includes(:depends_on_job).find_by!(satisfaction_mode: "landed")
    expect(dependency.depends_on_job).to have_attributes(kind: "direct", repository: repository)
    expect(parse_body.fetch("message")).to include(dependency.depends_on_job.slug)
  end
end
