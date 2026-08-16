require "rails_helper"

RSpec.describe IndexOperationalLogEventsJob do
  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Factories.repository(user: Factories.user, owner: "tkadauke", name: "syrus")
    Current.reset
  end

  after { Current.reset }

  it "indexes existing events and deletes missing events in one job" do
    prepare_search_tables
    event = OperationalLogEvent.create!(
      occurred_at: Time.current,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "batched index me",
      context: {}
    )

    described_class.perform_now([ event.id, 999_999 ])

    expect(OperationalLogIndex.search(query: "batched", since: 1.hour.ago).map { |row| row[:operational_log_event_id] }).to include(event.id)
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
