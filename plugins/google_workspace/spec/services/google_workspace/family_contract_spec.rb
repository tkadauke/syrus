require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe GoogleWorkspace::CalendarAdapter do
  ContractAccount = Data.define(:provider) unless const_defined?(:ContractAccount)
  available = PersonalCalendar::Context.new(account: ContractAccount.new(provider: "google_workspace"), access: Object.new,
    arguments: { "event_id" => "missing", "starts_at" => Time.current.iso8601, "ends_at" => 1.hour.from_now.iso8601 })
  unavailable = PersonalCalendar::Context.new(account: ContractAccount.new(provider: "other"), access: Object.new, arguments: {})

  before do
    allow(described_class).to receive(:get).and_return({ "items" => [] }, {})
  end

  it_behaves_like "a valid personal_calendar provider",
    plugin: "google_workspace", provider: "GoogleWorkspace::CalendarAdapter",
    contexts: -> { { list_events: available, get_event: available } },
    decline_contexts: -> { { list_events: unavailable, get_event: unavailable } }
end


RSpec.describe GoogleWorkspace::MailAdapter do
  MailContractAccount = Data.define(:provider) unless const_defined?(:MailContractAccount)
  available = SyrusMail::Context.new(account: MailContractAccount.new(provider: "google_workspace"), access: Object.new,
    arguments: { "query" => "", "message_id" => "missing" })
  unavailable = SyrusMail::Context.new(account: MailContractAccount.new(provider: "other"), access: Object.new, arguments: {})

  before do
    allow(described_class).to receive(:get).and_return({ "messages" => [] }, { "id" => "missing", "payload" => {} })
  end

  it_behaves_like "a valid mail provider",
    plugin: "google_workspace", provider: "GoogleWorkspace::MailAdapter",
    contexts: -> { { search: available, read_message: available } },
    decline_contexts: -> { { search: unavailable, read_message: unavailable } }
end
