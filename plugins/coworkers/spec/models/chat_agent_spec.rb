require "rails_helper"

RSpec.describe Coworkers::ChatAgent do
  before { PluginRecord.find_by!(name: "coworkers").update!(enabled: true) }

  it "requires the coworker to belong to the chat owner" do
    owner = Factories.user
    other = Factories.user(email_address: "other-agent@example.com")
    chat = ChatSession.create!(user: owner, title: "Plans")
    coworker = Coworkers::Coworker.create!(owner_user: other, name: "Other", handle: "foreign-coworker", workspace_repo: "https://github.com/acme/other.git")

    entry = described_class.new(chat_session: chat, coworker: coworker, added_by_user: owner)

    expect(entry).not_to be_valid
    expect(entry.errors[:coworker]).to include("must belong to the chat owner")
  end
end
