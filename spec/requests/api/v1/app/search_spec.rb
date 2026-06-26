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

  it "returns 400 when the query is blank or too short" do
    get "/api/v1/app/search", params: { q: " a " }

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "code")).to eq("bad_request")
  end

  it "rejects unknown result types" do
    get "/api/v1/app/search", params: { q: "deploy", types: [ "job", "note" ] }

    expect(response).to have_http_status(:bad_request)
    expect(parse_body.dig("error", "message")).to include("job, epic, or chat")
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

    get "/api/v1/app/search", params: { q: "deploy" }

    expect(response).to have_http_status(:ok)
    results = parse_body
    by_type_and_id = results.index_by { |row| [ row.fetch("type"), row.fetch("id") ] }
    expect(results.map { |row| row["type"] }).to contain_exactly("job", "job", "epic", "chat")
    expect(by_type_and_id.fetch([ "job", stronger_job.id ])).to include(
      "type" => "job",
      "id" => stronger_job.id,
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

    get "/api/v1/app/search", params: { q: "deploy", types: [ "job" ], limit: 500 }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to contain_exactly(include("type" => "job", "id" => job.id))
  end

  it "does not leak indexed records that no longer belong to the current user" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user, owner: "other", name: "private")
    other_job = Factories.job_record(user: other_user, repository: other_repo, issue_title: "Private deploy")
    JobSearchIndex.upsert(other_job)

    get "/api/v1/app/search", params: { q: "deploy" }

    expect(response).to have_http_status(:ok)
    expect(parse_body).to eq([])
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS job_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS epic_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
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
  end
end
