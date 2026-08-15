require "rails_helper"
require "rake"

RSpec.describe "syrus:prepare_search" do
  before(:all) do
    Rails.application.load_tasks
  end

  before do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS operational_log_fts")
    Rake::Task["syrus:prepare_search"].reenable
  end

  it "creates missing search virtual tables" do
    Rake::Task["syrus:prepare_search"].invoke

    expect(OperationalLogIndex.available?).to be(true)
  end

  it "rebuilds and repopulates a table whose column set drifted from a stale pre-existing schema" do
    stale_event = OperationalLogEvent.create!(
      occurred_at: 1.minute.ago,
      level: "error",
      role: "worker",
      hostname: "host-a",
      source: "spec",
      message: "grader failed",
      context: {}
    )

    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE operational_log_fts
      USING fts5(
        message,
        context_text,
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

    expect { OperationalLogIndex.search(since: 1.hour.ago) }
      .to raise_error(ActiveRecord::StatementInvalid, /no such column: context_json/)

    Rake::Task["syrus:prepare_search"].invoke

    results = OperationalLogIndex.search(since: 1.hour.ago)
    expect(results.map { |row| row[:operational_log_event_id] }).to eq([ stale_event.id ])
  end

  it "leaves a drifted table without a repopulation hook in place instead of destroying its rows" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS job_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE job_fts
      USING fts5(
        title,
        job_id UNINDEXED,
        user_id UNINDEXED,
        repository_id UNINDEXED,
        state UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      INSERT INTO job_fts (title, job_id, user_id, repository_id, state, created_at)
      VALUES ('irreplaceable row', 1, 1, 1, 'open', '2026-01-01')
    SQL

    Rake::Task["syrus:prepare_search"].invoke

    expect(SearchRecord.connection.select_value("SELECT COUNT(*) FROM job_fts")).to eq(1)
  ensure
    SearchRecord.connection.execute("DROP TABLE IF EXISTS job_fts")
    SyrusSearchDatabaseTasks.ensure_required_tables!
  end
end
