require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe Mail::FakeAdapter do
  Account = Data.define(:provider) unless const_defined?(:Account)
  available = Mail::Context.new(account: Account.new(provider: "fake"), access: Object.new,
    arguments: { "query" => "", "message_id" => "missing" })
  unavailable = Mail::Context.new(account: Account.new(provider: "other"), access: Object.new, arguments: {})

  it_behaves_like "a valid mail provider",
    plugin: "mail", provider: "Mail::FakeAdapter",
    contexts: -> { { search: available, read_message: available } },
    decline_contexts: -> { { search: unavailable, read_message: unavailable } }
end
