require "rails_helper"

RSpec.describe Mcp::Tools::AdminReadOperationalLogsTool do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: admin, owner: "tkadauke", name: "syrus") }
  let(:admin_chat_session) { ChatSession.create!(user: admin, repository: repository) }
  let(:non_admin_chat_session) { ChatSession.create!(user: user, repository: Factories.repository(user: user)) }

  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Current.reset
    prepare_search_tables
  end

  after { Current.reset }

  it "rejects non-admin chat contexts" do
    response = described_class.call(server_context: { chat_session: non_admin_chat_session })

    expect(response).to be_error
    expect(response.content.first[:text]).to include("Unauthorized")
  end

  it "returns a clear disabled response when the feature is off" do
    Feature.find_by!(slug: "operational_log_indexing").update!(enabled: false)
    Current.reset

    response = described_class.call(server_context: { chat_session: admin_chat_session })

    expect(response).not_to be_error
    expect(payload_from(response)).to include(
      "enabled" => false,
      "error" => "operational_log_indexing_disabled"
    )
  end

  it "allows admin chat contexts to query and returns redacted matching logs" do
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
      server_context: { chat_session: admin_chat_session },
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
    response = described_class.call(server_context: { chat_session: admin_chat_session }, level: "verbose")

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
