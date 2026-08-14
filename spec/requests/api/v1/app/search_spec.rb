require "rails_helper"

RSpec.describe "App API unified search", type: :request do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
    sign_in_as(user)
  end

  def parse_body
    JSON.parse(response.body)
  end

  def results
    parse_body.fetch("results")
  end

  def filter_q(tree)
    Filters::QueryParam.encode(tree)
  end

  it "returns 400 when the query is blank or too short" do
    get "/api/v1/app/search", params: { query: " a " }

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "code")).to eq("bad_request")
  end

  it "rejects unknown result types" do
    get "/api/v1/app/search", params: { query: "deploy", types: [ "job", "note" ] }

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "message")).to include("job, epic, chat, or test_case")
  end

  it "merges jobs, epics, and chat messages into normalized ranked results" do
    weaker_job = Factories.job_record(user: user, repository: repository, issue_title: "Weaker job")
    stronger_job = Factories.job_record(user: user, repository: repository, issue_title: "Stronger job", state: "running")
    epic = Factories.epic(user: user, repository: repository, title: "Launch epic", state: "in_progress")
    chat_session = ChatSession.create!(user: user, repository: repository, title: "Launch chat")
    chat_message = ChatMessage.create!(chat_session: chat_session, role: "assistant", content: { "text" => "deploy transcript" })

    weaker_job.update!(issue_body: "deploy transcript")
    stronger_job.update!(issue_body: "deploy deploy deploy transcript")
    epic.update!(description: "deploy planning")
    JobSearchIndex.upsert(weaker_job)
    JobSearchIndex.upsert(stronger_job)
    EpicSearchIndex.upsert(epic)
    ChatMessageSearchIndex.insert(chat_message)

    get "/api/v1/app/search", params: { query: "deploy" }

    expect(response).to have_http_status(:ok)
    by_type_and_id = results.index_by { |row| [ row.fetch("type"), row.fetch("id") ] }
    expect(results.map { |row| row["type"] }).to contain_exactly("job", "job", "epic", "chat")
    expect(by_type_and_id.fetch([ "job", stronger_job.id ])).to include(
      "type" => "job",
      "id" => stronger_job.id,
      "slug" => stronger_job.slug,
      "title" => "Stronger job",
      "rank" => 0.0,
      "path" => job_path(stronger_job),
      "state" => "running",
      "repository_slug" => "acme/widgets",
      "created_at" => stronger_job.created_at.iso8601
    )
    expect(by_type_and_id.fetch([ "job", stronger_job.id ]).fetch("snippet")).to include("<mark>deploy</mark>")
    expect(by_type_and_id.fetch([ "job", weaker_job.id ])).to include("rank" => 1.0)
    expect(by_type_and_id.fetch([ "epic", epic.id ])).to include(
      "type" => "epic",
      "id" => epic.id,
      "slug" => epic.slug,
      "title" => "Launch epic",
      "rank" => 0.0,
      "path" => epic_path(epic),
      "state" => "in_progress",
      "repository_slug" => "acme/widgets"
    )
    expect(by_type_and_id.fetch([ "chat", chat_message.id ])).to include(
      "type" => "chat",
      "id" => chat_message.id,
      "title" => "Launch chat",
      "rank" => 0.0,
      "path" => chat_path(chat_session, message_id: chat_message.id),
      "state" => nil,
      "repository_slug" => nil
    )
  end

  it "limits searches to requested types" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Deploy job")
    epic = Factories.epic(user: user, repository: repository, title: "Deploy epic")
    chat_session = ChatSession.create!(user: user, repository: repository, title: "Deploy chat")
    chat_message = ChatMessage.create!(chat_session: chat_session, role: "user", content: { "text" => "deploy chat" })
    JobSearchIndex.upsert(job)
    EpicSearchIndex.upsert(epic)
    ChatMessageSearchIndex.insert(chat_message)

    get "/api/v1/app/search", params: { query: "deploy", types: [ "job" ], limit: 500 }

    expect(response).to have_http_status(:ok)
    expect(results).to contain_exactly(include("type" => "job", "id" => job.id))
  end

  it "uses query as the canonical full text search parameter" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Canonical deploy job")
    JobSearchIndex.upsert(job)

    get "/api/v1/app/search", params: { query: "deploy" }

    expect(response).to have_http_status(:ok)
    expect(results).to include(include("type" => "job", "id" => job.id))
    expect(parse_body.dig("controls", "filter_schema").map { |field| field.fetch("field") }).to include("repository_id", "created_at", "updated_at")
  end

  it "falls back to legacy plain-text q when query is absent" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Legacy deploy job")
    JobSearchIndex.upsert(job)

    get "/api/v1/app/search", params: { q: "deploy" }

    expect(response).to have_http_status(:ok)
    expect(results).to include(include("type" => "job", "id" => job.id))
    expect(parse_body.fetch("filter")).to be_nil
  end

  it "returns an existing job when searching by JOB slug" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Unindexed slug target")

    get "/api/v1/app/search", params: { query: job.slug }

    expect(response).to have_http_status(:ok)
    expect(results).to include(
      include(
        "type" => "job",
        "id" => job.id,
        "slug" => job.slug,
        "title" => "Unindexed slug target",
        "snippet" => "<mark>#{job.slug}</mark>",
        "path" => job_path(job),
        "repository_slug" => "acme/widgets"
      )
    )
  end

  it "returns an existing epic when searching by EPIC slug" do
    epic = Factories.epic(user: user, repository: repository, title: "Unindexed epic target")

    get "/api/v1/app/search", params: { query: epic.slug }

    expect(response).to have_http_status(:ok)
    expect(results).to include(
      include(
        "type" => "epic",
        "id" => epic.id,
        "slug" => epic.slug,
        "title" => "Unindexed epic target",
        "snippet" => "<mark>#{epic.slug}</mark>",
        "path" => epic_path(epic),
        "repository_slug" => "acme/widgets"
      )
    )
  end

  it "groups chat message matches by chat session" do
    chat_session = ChatSession.create!(user: user, repository: repository, title: "Launch chat")
    best_message = ChatMessage.create!(chat_session: chat_session, role: "assistant", content: { "text" => "deploy deploy deploy transcript" }, created_at: 5.minutes.ago)
    grouped_messages = 4.times.map do |index|
      ChatMessage.create!(chat_session: chat_session, role: "user", content: { "text" => "deploy follow-up #{index}" }, created_at: index.minutes.ago)
    end
    other_chat = ChatSession.create!(user: user, repository: repository, title: "Other chat")
    other_message = ChatMessage.create!(chat_session: other_chat, role: "assistant", content: { "text" => "deploy elsewhere" })
    ([ best_message, other_message ] + grouped_messages).each { |message| ChatMessageSearchIndex.insert(message) }

    get "/api/v1/app/search", params: { query: "deploy", types: [ "chat" ] }

    expect(response).to have_http_status(:ok)
    expect(results.length).to eq(2)
    launch_result = results.find { |result| result["title"] == "Launch chat" }
    expect(launch_result).to include(
      "type" => "chat",
      "id" => best_message.id,
      "path" => chat_path(chat_session, message_id: best_message.id),
      "total_match_count" => 5,
      "has_more_matches" => true
    )
    expect(launch_result.fetch("grouped_matches").length).to eq(3)
    expect(launch_result.fetch("grouped_matches").map { |match| match.fetch("id") }).to match_array(grouped_messages.map(&:id).first(3))
    expect(results.find { |result| result["title"] == "Other chat" }).to include("total_match_count" => 1, "has_more_matches" => false)
  end

  it "returns test_case results with path to the associated job" do
    job = Factories.job_record(user: user, repository: repository)
    run = Run.create!(job: job, user: user, trigger_kind: "initial")
    test_run = TestRun.create!(
      run: run,
      repository: repository,
      grader_name: "rspec",
      total_count: 1,
      passed_count: 0,
      failed_count: 1,
      skipped_count: 0,
      error_count: 0
    )
    test_case = TestCase.create!(
      test_run: test_run,
      repository: repository,
      name: "LoginService validates credentials uniquely",
      suite_name: "AuthSpec",
      file_path: "spec/services/login_service_spec.rb",
      status: "failed"
    )
    TestCaseSearchIndex.upsert(test_case)

    get "/api/v1/app/search", params: { query: "LoginService", types: [ "test_case" ] }

    expect(response).to have_http_status(:ok)
    expect(results.length).to eq(1)
    expect(results.first).to include(
      "type" => "test_case",
      "id" => test_case.id,
      "title" => "LoginService validates credentials uniquely",
      "suite_name" => "AuthSpec",
      "file_path" => "spec/services/login_service_spec.rb",
      "state" => "failed",
      "path" => job_path(job),
      "repository_slug" => "acme/widgets"
    )
    expect(results.first.fetch("snippet")).to include("<mark>")
  end

  it "does not leak indexed records that no longer belong to the current user" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
    other_job = Factories.job_record(user: other_user, repository: other_repo, issue_title: "Private deploy")
    JobSearchIndex.upsert(other_job)

    get "/api/v1/app/search", params: { query: "deploy" }

    expect(response).to have_http_status(:ok)
    expect(results).to eq([])
  end

  it "uses q as an encoded filter AST when query is present" do
    queued_job = Factories.job_record(user: user, repository: repository, issue_title: "Deploy queued job", state: "queued")
    closed_job = Factories.job_record(user: user, repository: repository, issue_title: "Deploy closed job", state: "closed")
    [ queued_job, closed_job ].each { |job| JobSearchIndex.upsert(job) }
    tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "closed" } ] }

    get "/api/v1/app/search", params: { query: "deploy", q: filter_q(tree), types: [ "job" ] }

    expect(response).to have_http_status(:ok)
    expect(results).to contain_exactly(include("type" => "job", "id" => closed_job.id))
    expect(parse_body.fetch("filter")).to eq(tree)
  end

  it "uses the job filter schema and narrows jobs by state" do
    queued_job = Factories.job_record(user: user, repository: repository, issue_title: "Deploy queued job", state: "queued")
    running_job = Factories.job_record(user: user, repository: repository, issue_title: "Deploy running job", state: "running")
    [ queued_job, running_job ].each { |job| JobSearchIndex.upsert(job) }
    tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "running" } ] }

    get "/api/v1/app/search", params: { query: "deploy", q: filter_q(tree), types: [ "job" ] }

    expect(response).to have_http_status(:ok)
    expect(results).to contain_exactly(include("type" => "job", "id" => running_job.id))
    expect(parse_body.dig("controls", "filter_schema").map { |field| field.fetch("field") }).to include("state", "priority", "repository_id")
  end

  it "uses the epic filter schema and narrows epics by state" do
    backlog_epic = Factories.epic(user: user, repository: repository, title: "Deploy backlog epic", state: "backlog")
    active_epic = Factories.epic(user: user, repository: repository, title: "Deploy active epic", state: "in_progress")
    [ backlog_epic, active_epic ].each { |epic| EpicSearchIndex.upsert(epic) }
    tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "in_progress" } ] }

    get "/api/v1/app/search", params: { query: "deploy", q: filter_q(tree), types: [ "epic" ] }

    expect(response).to have_http_status(:ok)
    expect(results).to contain_exactly(include("type" => "epic", "id" => active_epic.id))
    expect(parse_body.dig("controls", "filter_schema").map { |field| field.fetch("field") }).to include("state", "repository_id", "created_at")
  end

  it "applies common created_at filters to supported result types" do
    older_job = Factories.job_record(user: user, repository: repository, issue_title: "Deploy old job", created_at: 5.days.ago)
    newer_job = Factories.job_record(user: user, repository: repository, issue_title: "Deploy new job", created_at: 1.hour.ago)
    [ older_job, newer_job ].each { |job| JobSearchIndex.upsert(job) }
    tree = { "and" => [ { "field" => "created_at", "op" => "after", "value" => 1.day.ago.iso8601 } ] }

    get "/api/v1/app/search", params: { query: "deploy", q: filter_q(tree), types: [ "job" ] }

    expect(response).to have_http_status(:ok)
    expect(results).to contain_exactly(include("type" => "job", "id" => newer_job.id))
  end

  it "preserves relevance ordering after filters are applied" do
    weaker_job = Factories.job_record(user: user, repository: repository, issue_title: "Weaker matching deploy job", state: "running")
    stronger_job = Factories.job_record(user: user, repository: repository, issue_title: "Stronger matching deploy job", state: "running")
    excluded_job = Factories.job_record(user: user, repository: repository, issue_title: "Excluded deploy job", state: "queued")
    weaker_job.update!(issue_body: "deploy transcript")
    stronger_job.update!(issue_body: "deploy deploy deploy transcript")
    excluded_job.update!(issue_body: "deploy deploy deploy deploy transcript")
    [ weaker_job, stronger_job, excluded_job ].each { |job| JobSearchIndex.upsert(job) }
    tree = { "and" => [ { "field" => "state", "op" => "is", "value" => "running" } ] }

    get "/api/v1/app/search", params: { query: "deploy", q: filter_q(tree), types: [ "job" ] }

    expect(response).to have_http_status(:ok)
    expect(results.map { |row| row.fetch("id") }).to eq([ stronger_job.id, weaker_job.id ])
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS job_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS epic_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS test_case_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE job_fts
      USING fts5(
        title,
        body,
        job_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        state UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE epic_fts
      USING fts5(
        title,
        description,
        epic_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        state UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(
        content,
        user_id UNINDEXED,
        chat_session_id UNINDEXED,
        chat_message_id UNINDEXED,
        role UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE TABLE chat_search_metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE test_case_fts
      USING fts5(
        name,
        suite_name,
        file_path,
        test_case_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        status UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
