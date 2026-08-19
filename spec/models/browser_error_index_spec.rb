require "rails_helper"
require "rake"

RSpec.describe BrowserErrorIndex do
  before(:all) do
    Rails.application.load_tasks
  end

  before do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS browser_error_fts")
    Rake::Task["syrus:prepare_search"].reenable
    Rake::Task["syrus:prepare_search"].invoke
  end

  it "indexes browser error diagnostic fields for full text search" do
    event = BrowserErrorEvent.record!(
      user: Factories.user,
      payload: {
        "fingerprint" => "stack-fingerprint",
        "name" => "TypeError",
        "message" => "undefined is not an object",
        "stack" => "at JobWorkflowList.map",
        "path" => "/jobs/3188"
      }
    )

    described_class.upsert(event)

    expect(described_class.search(query: "JobWorkflowList", since: 1.hour.ago)).to eq([ event.id ])
  end

  it "memoizes table availability instead of re-querying sqlite_master on every call" do
    described_class.reset_availability_cache!
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql].to_s if payload[:sql].to_s.include?("sqlite_master")
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      3.times { described_class.available? }
    end

    expect(queries.size).to eq(1)
  end

  it "recomputes availability after an explicit cache reset" do
    expect(described_class.available?).to be(true)

    SearchRecord.connection.execute("DROP TABLE IF EXISTS browser_error_fts")
    described_class.reset_availability_cache!

    expect(described_class.available?).to be(false)
  end
end
