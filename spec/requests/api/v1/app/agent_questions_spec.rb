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

  it "forbids a visible read-tier member from answering" do
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Ship it?", "options" => [ "Yes", "No" ], "multiple" => false } ])
    reader = Factories.user
    repository.repository_memberships.create!(user: reader, role: "read")
    sign_in_as(reader)

    post "/api/v1/app/agent_questions/#{question.id}/answer", params: { answers: [ "Yes" ] }

    expect(response).to have_http_status(:forbidden)
    expect(question.reload).to be_active
  end

  it "retires an awaiting-answer workflow before retrying implementation" do
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Ship it?", "options" => [ "Yes", "No" ], "multiple" => false } ])
    workflow = run.workflow
    job.update_columns(state: "running")
    workflow.update_columns(state: "running", started_at: 2.minutes.ago)
    run.step.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    run.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    attach_work_unit(workflow, state: "running") unless workflow.work_unit

    post "/api/v1/app/jobs/#{job.id}/retry_implementation"

    expect(response).to have_http_status(:ok), response.body
    expect(question.reload.withdrawn_at).to be_present
    expect(workflow.reload).to be_cancelled
    expect(job.workflows.where(trigger_kind: "retry")).to exist
  end

  it "retires the waiting step and question when the Job is cancelled, and a later answer does not resume it" do
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Ship it?", "options" => [ "Yes", "No" ], "multiple" => false } ])
    workflow = run.workflow
    job.update_columns(state: "running")
    workflow.update_columns(state: "running", started_at: 2.minutes.ago)
    run.step.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    run.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    attach_work_unit(workflow, state: "running") unless workflow.work_unit

    post "/api/v1/app/jobs/#{job.id}/cancel"

    expect(response).to have_http_status(:ok), response.body
    expect(workflow.reload).to be_cancelled
    expect(run.reload).to be_cancelled
    expect(run.step.reload).to be_cancelled
    expect(question.reload.withdrawn_at).to be_present
    expect(workflow.active_agent_questions?).to be(false)

    question.update_columns(withdrawn_at: nil)
    expect(AgentQuestions::Resume.call(question.reload)).to be(false)
    expect(run.reload).to be_cancelled
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
    user.update!(claude_oauth_token: "claude-token")
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Which dependency?", "options" => nil, "multiple" => false } ])
    workflow = run.workflow
    job.update_columns(state: "running")
    workflow.update_columns(state: "running", started_at: 2.minutes.ago)
    run.step.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    run.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    attach_work_unit(workflow, state: "running") unless workflow.work_unit

    post "/api/v1/app/jobs/#{job.id}/file_question_fix"

    expect(response).to have_http_status(:ok)
    dependency = job.dependencies.includes(:depends_on_job).find_by!(satisfaction_mode: "landed")
    expect(dependency.depends_on_job).to have_attributes(kind: "direct", repository: repository)
    expect(parse_body.fetch("message")).to include(dependency.depends_on_job.slug)
    expect(question.reload.withdrawn_at).to be_present
    expect(workflow.reload).to be_cancelled
    retry_workflow = job.workflows.where(trigger_kind: "retry").order(:id).last
    expect(retry_workflow).to be_present
    expect(retry_workflow).to be_queued
    expect(job.reload).to be_queued

    dependency.depends_on_job.update!(landed_sha: "landed-fix-sha")
    dependency.depends_on_job.close_with_reason!("pr_merged")

    expect(dependency.reload).to be_execution_dependency_satisfied
    expect(job.reload).to be_queued
    expect(retry_workflow.reload.runs.active).to exist
  end

  it "rolls back the fix Job and dependency when the retry transition fails" do
    question = AgentQuestion.create!(run:, asked_at: Time.current, questions: [ { "question" => "Which dependency?", "options" => nil, "multiple" => false } ])
    workflow = run.workflow
    job.update_columns(state: "running")
    workflow.update_columns(state: "running", started_at: 2.minutes.ago)
    run.step.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    run.update_columns(state: "awaiting_answer", started_at: 2.minutes.ago)
    attach_work_unit(workflow, state: "running") unless workflow.work_unit
    allow(RetryWorkflowEnqueuer).to receive(:call).and_return(
      RetryWorkflowEnqueuer::Result.new(workflow: nil, error: "Retry could not start.", circuit: nil)
    )

    expect {
      post "/api/v1/app/jobs/#{job.id}/file_question_fix"
    }.not_to change(Job, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(job.reload.dependencies).to be_empty
    expect(question.reload).to be_active
    expect(workflow.reload).to be_running
  end
end
