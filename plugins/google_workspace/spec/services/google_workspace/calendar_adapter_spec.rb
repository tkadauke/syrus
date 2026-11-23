require "rails_helper"

RSpec.describe GoogleWorkspace::CalendarAdapter do
  Account = Data.define(:provider, :id) unless const_defined?(:Account)
  Access = Data.define(:authorization_header) unless const_defined?(:Access)
  let(:account) { Account.new(provider: "google_workspace", id: 17) }
  let(:access) { Access.new(authorization_header: "Bearer secret-access-token") }
  let(:arguments) do
    { "starts_at" => "2026-11-22T00:00:00Z", "ends_at" => "2026-11-25T00:00:00Z", "limit" => 10, "event_id" => "timed" }
  end
  let(:context) { PersonalCalendar::Context.new(account:, access:, arguments:) }
  let(:fixture_root) { Rails.root.join("plugins/google_workspace/spec/fixtures/google_workspace") }

  it "pages and normalizes timed, recurring, time-zone, and all-day events" do
    stub_request(:get, %r{www.googleapis.com/calendar/v3/calendars/primary/events})
      .with { |request| !request.uri.query.include?("pageToken") }
      .to_return(status: 200, body: fixture_root.join("events_page_1.json").read)
    stub_request(:get, %r{www.googleapis.com/calendar/v3/calendars/primary/events})
      .with { |request| request.uri.query.include?("pageToken=page-2") }
      .to_return(status: 200, body: fixture_root.join("events_page_2.json").read)

    events = described_class.list_events(context).fetch("events")

    expect(events.first).to include("id" => "timed", "recurring_event_id" => "series-1",
      "time_zone" => "Europe/Berlin", "all_day" => false)
    expect(events.second).to include("id" => "all-day", "start" => "2026-11-23", "all_day" => true)
  end

  it "gets one event and URL-escapes its id" do
    request = stub_request(:get, "https://www.googleapis.com/calendar/v3/calendars/primary/events/a%2Fb")
      .to_return(status: 200, body: fixture_root.join("events_page_1.json").then { |path| JSON.parse(path.read).fetch("items").first.to_json })
    result = described_class.get_event(PersonalCalendar::Context.new(account:, access:, arguments: arguments.merge("event_id" => "a/b")))
    expect(result.dig("event", "id")).to eq("timed")
    expect(request).to have_been_requested
  end

  it "maps rate-limit responses to a typed retryable problem without leaking credentials" do
    stub_request(:get, %r{www.googleapis.com/calendar/v3/}).to_return(status: 429, headers: { "Retry-After" => "60" }, body: "quota")
    expect { described_class.list_events(context) }.to raise_error(GoogleWorkspace::CalendarProblem) { |error|
      expect(error.code).to eq("quota_limited")
      expect(error.retry_after).to eq("60")
      expect(error.message).not_to include("secret-access-token")
    }
  end


  it "maps Google quota reasons to the same typed retryable problem" do
    body = { error: { errors: [ { reason: "quotaExceeded" } ] } }.to_json
    stub_request(:get, %r{www.googleapis.com/calendar/v3/}).to_return(status: 403, headers: { "Retry-After" => "120" }, body:)
    expect { described_class.get_event(context) }.to raise_error(GoogleWorkspace::CalendarProblem) { |error|
      expect(error.code).to eq("quota_limited")
      expect(error.retry_after).to eq("120")
    }
  end

  it "marks a revoked grant as needing reauthorization through the broker" do
    stub_request(:get, %r{www.googleapis.com/calendar/v3/}).to_return(status: 401, body: "revoked")
    allow(ConnectedAccounts::OauthBroker).to receive(:needs_reauth!).with(account)
    expect { described_class.get_event(context) }.to raise_error(GoogleWorkspace::CalendarProblem) { |error|
      expect(error.code).to eq("needs_reauth")
    }
    expect(ConnectedAccounts::OauthBroker).to have_received(:needs_reauth!).with(account)
  end

  it "declines accounts from other providers" do
    other = Account.new(provider: "other", id: 18)
    expect(described_class.list_events(PersonalCalendar::Context.new(account: other, access:, arguments:))).to be_nil
  end
end
