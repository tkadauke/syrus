require "rails_helper"
require "syrus/plugin/test_kit"

RSpec.describe SyrusMail::FakeAdapter do
  Account = Data.define(:provider) unless const_defined?(:Account)
  available = SyrusMail::Context.new(account: Account.new(provider: "fake"), access: Object.new,
    arguments: { "query" => "", "message_id" => "missing" })
  unavailable = SyrusMail::Context.new(account: Account.new(provider: "other"), access: Object.new, arguments: {})

  it_behaves_like "a valid mail provider",
    plugin: "mail", provider: "SyrusMail::FakeAdapter",
    contexts: -> { { search: available, read_message: available } },
    decline_contexts: -> { { search: unavailable, read_message: unavailable } }
end

RSpec.describe "mail plugin namespace" do
  it "does not add Syrus plugin APIs to the mail gem namespace" do
    expect(Mail).not_to respond_to(:syrus_plugin_definition)
    expect(SyrusMail).to respond_to(:syrus_plugin_definition)
  end
end
