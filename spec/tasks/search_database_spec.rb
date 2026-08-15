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
end
