require "rails_helper"

RSpec.describe IndexBrowserErrorEventsJob do
  it "slices oversized id batches without dropping work" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS browser_error_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE browser_error_fts
      USING fts5(
        message,
        search_text,
        browser_error_event_id UNINDEXED,
        occurred_at UNINDEXED,
        app_revision UNINDEXED,
        fingerprint UNINDEXED,
        name UNINDEXED,
        path UNINDEXED,
        user_id UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    BrowserErrorIndex.reset_availability_cache!
    event = BrowserErrorEvent.record!(
      user: Factories.user,
      payload: { "fingerprint" => "past-slice", "message" => "past the slice" }
    )
    ids = Array.new(SearchIndexWriteLimits::MAX_BATCH_ROWS) { |index| -(index + 1) } << event.id

    described_class.perform_now(ids)

    expect(BrowserErrorIndex.search(query: "slice", since: 1.hour.ago)).to eq([ event.id ])
  end
end
