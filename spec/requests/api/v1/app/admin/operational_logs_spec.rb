require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/operational_logs", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let!(:non_admin) { Factories.user(admin: false) }
  let!(:repository) { Factories.repository(user: admin, owner: "tkadauke", name: "syrus") }

  def parse_body = JSON.parse(response.body)

  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    allow(SyrusVersion).to receive(:current).and_return("current-sha")
    allow(OperationalLogging).to receive(:enabled_for_instance?).and_return(true)
    Current.reset
    prepare_search_tables
  end

  after { Current.reset }

  it "401s with a JSON error when signed out" do
    get "/api/v1/app/admin/operational_logs"

    expect(response).to have_http_status(:unauthorized)
    expect(parse_body.dig("error", "code")).to eq("unauthorized")
  end

  it "403s with a JSON error for non-admin users" do
    sign_in_as(non_admin)

    get "/api/v1/app/admin/operational_logs"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  it "returns a disabled payload when operational indexing is off" do
    Feature.find_by!(slug: "operational_log_indexing").update!(enabled: false)
    Feature.clear_enabled_cache!("operational_log_indexing")
    allow(OperationalLogging).to receive(:enabled_for_instance?).and_return(false)
    Current.reset
    sign_in_as(admin)

    get "/api/v1/app/admin/operational_logs"

    expect(response).to have_http_status(:ok)
    expect(parse_body).to include(
      "enabled" => false,
      "logs" => [],
      "error" => include("code" => "operational_log_indexing_disabled")
    )
  end

  it "searches indexed logs with filters and redacts output" do
    job = Factories.job(repository: repository, user: admin)
    workflow = job.workflows.first
    run = job.initial_run
    matching = log_event(
      occurred_at: 10.minutes.ago,
      level: "error",
      role: "worker",
      hostname: "worker-a",
      app_revision: "current-sha",
      source: "active_job",
      job_id: job.id,
      workflow_id: workflow.id,
      run_id: run.id,
      message: "grader failed token=super-secret migration",
      context: { "path" => "/jobs", "api_key" => "api_key=raw-secret" }
    )
    ignored = log_event(
      occurred_at: 5.minutes.ago,
      level: "info",
      role: "web",
      hostname: "web-a",
      app_revision: "current-sha",
      source: "action_controller",
      message: "request finished"
    )
    [ matching, ignored ].each { |event| OperationalLogIndex.upsert(event) }
    sign_in_as(admin)

    get "/api/v1/app/admin/operational_logs", params: {
      query: "migration",
      level: "error",
      role: "worker",
      hostname: "worker-a",
      since: "1h",
      until: Time.current.iso8601,
      per_page: 500
    }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["enabled"]).to eq(true)
    expect(body["revision_scope"]).to eq("current")
    expect(body.dig("pagination", "per_page")).to eq(OperationalLogIndex::MAX_LIMIT)
    expect(body["logs"].size).to eq(1)
    expect(body.dig("logs", 0)).to include(
      "id" => matching.id,
      "level" => "error",
      "role" => "worker",
      "hostname" => "worker-a",
      "source" => "active_job",
      "job_id" => job.id,
      "workflow_id" => workflow.id,
      "run_id" => run.id
    )
    expect(body.to_json).not_to include("super-secret", "raw-secret")
    expect(body.dig("logs", 0, "message")).to include("token=[REDACTED]")
    expect(body.dig("logs", 0, "context")).to include("api_key" => "api_key=[REDACTED]")
  end

  it "paginates and can include all revisions" do
    newest = log_event(occurred_at: 5.minutes.ago, app_revision: "other-sha", message: "newest")
    middle = log_event(occurred_at: 10.minutes.ago, app_revision: "current-sha", message: "middle")
    oldest = log_event(occurred_at: 15.minutes.ago, app_revision: "current-sha", message: "oldest")
    [ newest, middle, oldest ].each { |event| OperationalLogIndex.upsert(event) }
    sign_in_as(admin)

    get "/api/v1/app/admin/operational_logs", params: { revision_scope: "all", per_page: 2, page: 1 }

    expect(response).to have_http_status(:ok)
    body = parse_body
    expect(body["logs"].map { |row| row["id"] }).to eq([ newest.id, middle.id ])
    expect(body.dig("pagination", "has_next_page")).to be(true)

    get "/api/v1/app/admin/operational_logs", params: { revision_scope: "all", per_page: 2, page: 2 }

    expect(parse_body["logs"].map { |row| row["id"] }).to eq([ oldest.id ])
    expect(parse_body.dig("pagination", "has_previous_page")).to be(true)
  end

  it "rejects invalid bounded filters" do
    sign_in_as(admin)

    get "/api/v1/app/admin/operational_logs", params: { role: "mcp_sidecar" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(parse_body.dig("error", "code")).to eq("invalid_operational_log_search")
  end

  def log_event(**attrs)
    OperationalLogEvent.create!({
      occurred_at: Time.current,
      level: "info",
      role: "worker",
      hostname: "host-a",
      app_revision: "current-sha",
      pid: 123,
      source: "spec",
      message: "message",
      context: {}
    }.merge(attrs))
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS operational_log_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE operational_log_fts
      USING fts5(
        message,
        context_text,
        context_json UNINDEXED,
        operational_log_event_id UNINDEXED,
        occurred_at UNINDEXED,
        level UNINDEXED,
        role UNINDEXED,
        hostname UNINDEXED,
        app_revision UNINDEXED,
        pid UNINDEXED,
        source UNINDEXED,
        job_id UNINDEXED,
        workflow_id UNINDEXED,
        run_id UNINDEXED,
        request_id UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
