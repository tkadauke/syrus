require "rails_helper"

RSpec.describe SyrusMcp::ReadSyrusLogsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "tkadauke", name: "syrus") }
  let(:run) { Factories.job(repository: repository, user: user).initial_run }

  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Current.reset
    prepare_search_tables
  end

  after { Current.reset }

  it "returns a clear disabled response when the feature is off" do
    Feature.find_by!(slug: "operational_log_indexing").update!(enabled: false)
    Current.reset

    response = described_class.call(server_context: { run_id: run.id })

    expect(response).not_to be_error
    expect(payload_from(response)).to include(
      "enabled" => false,
      "error" => "operational_log_indexing_disabled"
    )
  end

  it "rejects a normal repository even when called directly" do
    normal_run = Factories.job.initial_run

    response = described_class.call(server_context: { run_id: normal_run.id })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("only available for Syrus repositories")
  end

  it "rejects non-implementation workflow roles" do
    review_step = Step.create!(workflow: run.workflow, kind: "adversarial_review", position: 99)
    review_run = Run.create!(job: run.job, user: run.user, step: review_step, trigger_kind: "initial")

    response = described_class.call(server_context: { run_id: review_run.id })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("not_authorized")
  end

  it "enforces bounds and returns redacted matching logs" do
    2.times do |index|
      event = OperationalLogEvent.create!(
        occurred_at: index.minutes.ago,
        level: "error",
        role: "worker",
        hostname: "host-a",
        app_revision: "sha",
        pid: 123,
        source: "spec",
        request_id: "req-#{index}",
        message: "failed token=[REDACTED] migration #{index}",
        context: { "path" => "/jobs", "api_key" => "api_key=[REDACTED]" }
      )
      OperationalLogIndex.upsert(event)
    end

    response = described_class.call(
      server_context: { run_id: run.id },
      query: "migration",
      since: "1d",
      level: "error",
      role: "worker",
      hostname: "host-a",
      limit: 500
    )

    expect(response).not_to be_error
    payload = payload_from(response)
    expect(payload["enabled"]).to be(true)
    expect(payload["count"]).to eq(2)
    expect(payload["logs"].size).to eq(2)
    expect(payload.to_json).not_to include("secret")
    expect(payload.dig("logs", 0, "message")).to include("[REDACTED]")
    expect(payload.dig("logs", 0, "context")).to include("path" => "/jobs", "api_key" => "api_key=[REDACTED]")
  end

  it "rejects invalid parameters" do
    response = described_class.call(server_context: { run_id: run.id }, level: "verbose")

    expect(response).to be_error
    expect(response.content.first[:text]).to include("level must be one of")
  end

  def payload_from(response)
    JSON.parse(response.content.first[:text])
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
