require "rails_helper"

RSpec.describe PruneOperationalLogsJob do
  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Factories.repository(user: Factories.user, owner: "tkadauke", name: "syrus")
    Current.reset
  end

  after { Current.reset }

  def event(occurred_at:)
    OperationalLogEvent.create!(
      occurred_at: occurred_at,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "hello",
      context: {}
    )
  end

  it "deletes events older than the retention window" do
    prepare_search_tables
    old = event(occurred_at: (OperationalLogEvent.retention_window + 1.minute).ago)
    fresh = event(occurred_at: 1.minute.ago)

    described_class.perform_now

    expect(OperationalLogEvent.exists?(old.id)).to be false
    expect(OperationalLogEvent.exists?(fresh.id)).to be true
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(operational_log_event_retention_hours: 0)
    old = event(occurred_at: 10.years.ago)

    described_class.perform_now

    expect(OperationalLogEvent.exists?(old.id)).to be true
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
