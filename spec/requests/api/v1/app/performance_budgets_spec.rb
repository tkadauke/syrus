require "rails_helper"

RSpec.describe "App API structural performance budgets", type: :request do
  let(:user) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    sign_in_as(user)
    allow(RepoDeploymentStagesReader).to receive(:for_repository)
      .and_return(RepoDeploymentStagesReader::Result.new(stages: [], source: "none", note: nil))
  end

  it "keeps dashboard chrome bounded" do
    create_dashboard_fixture

    metrics = capture_performance_budget do
      get "/api/v1/app/dashboard", params: { subject: "job", section: "chrome" }
    end

    expect(response).to have_http_status(:ok)
    expect_performance_budget(
      metrics,
      max_sql: 90,
      max_payload_bytes: 80.kilobytes,
      max_duplicate_fingerprints: 12,
      forbidden_sql: [ /FORCE INDEX/i ]
    )
  end

  it "keeps dashboard rows bounded" do
    create_dashboard_fixture

    metrics = capture_performance_budget do
      get "/api/v1/app/dashboard", params: { subject: "job", section: "rows", smart_folder_id: "all" }
    end

    expect(response).to have_http_status(:ok)
    expect_performance_budget(
      metrics,
      max_sql: 90,
      max_payload_bytes: 140.kilobytes,
      max_duplicate_fingerprints: 30,
      forbidden_sql: [ /FORCE INDEX/i ]
    )
  end

  it "keeps large chat show payloads bounded" do
    chat = ChatSession.create!(user: user, repository: repository, title: "Large chat", last_message_at: Time.current)
    80.times do |index|
      chat.messages.create!(
        role: index.even? ? "user" : "assistant",
        content: { "text" => "Message #{index} " + ("x" * 200) },
        created_at: 80.minutes.ago + index.minutes
      )
    end
    20.times do |index|
      chat.messages.offset(index).first.bookmarks.create!(label: "Bookmark #{index}", kind: "topic")
    end

    metrics = capture_performance_budget do
      get "/api/v1/app/chats/#{chat.id}"
    end

    expect(response).to have_http_status(:ok)
    expect_performance_budget(
      metrics,
      max_sql: 65,
      max_payload_bytes: 220.kilobytes,
      forbidden_sql: [ /FROM "?chat_bookmarks"?/i ]
    )
  end

  it "keeps repository detail payloads bounded" do
    30.times do |index|
      state = index.even? ? "implemented" : "queued"
      run_state = index.even? ? "succeeded" : "running"
      job = Factories.job_record(
        repository: repository,
        owner_user: user,
        issue_number: index + 1,
        issue_title: "Repository job #{index}",
        state: state
      )
      workflow = Workflow.create!(job: job, user: user, trigger_kind: "initial", state: run_state)
      step = workflow.steps.create!(kind: "prepare", position: 0, state: workflow.state)
      step.runs.create!(job: job, user: user, trigger_kind: "initial", state: run_state)
    end

    metrics = capture_performance_budget do
      get "/api/v1/app/repositories/#{repository.id}"
    end

    expect(response).to have_http_status(:ok)
    expect_performance_budget(
      metrics,
      max_sql: 55,
      max_payload_bytes: 180.kilobytes,
      forbidden_sql: [ /FORCE INDEX/i, /workflows\.finished_at IS NULL/i ]
    )
  end

  private

  def create_dashboard_fixture
    SmartFolder.ensure_builtins_for_subject!("job")

    25.times do |index|
      job = Factories.job_record(
        repository: repository,
        owner_user: user,
        issue_number: index + 1,
        issue_title: "Dashboard job #{index}",
        state: index.even? ? "queued" : "implemented"
      )
      Workflow.create!(job: job, trigger_kind: "initial", state: index.even? ? "queued" : "succeeded")
    end
  end
end
