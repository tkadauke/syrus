require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe PersonalCalendar::FakeAdapter do
  Account = Data.define(:provider) unless const_defined?(:Account)
  available = PersonalCalendar::Context.new(account: Account.new(provider: "fake"), access: Object.new,
    arguments: { "event_id" => "missing" })
  unavailable = PersonalCalendar::Context.new(account: Account.new(provider: "other"), access: Object.new, arguments: {})

  it_behaves_like "a valid personal_calendar provider",
    plugin: "personal_calendar", provider: "PersonalCalendar::FakeAdapter",
    contexts: -> { { list_events: available, get_event: available } },
    decline_contexts: -> { { list_events: unavailable, get_event: unavailable } }
end
