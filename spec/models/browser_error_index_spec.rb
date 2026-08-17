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
end
