require "rails_helper"
require Rails.root.join("db/migrate/20260623170414_add_pending_action_to_chat_messages")

RSpec.describe AddPendingActionToChatMessages do
  it "is idempotent when run more than once" do
    migration = described_class.new

    expect {
      migration.up
      migration.up
    }.not_to raise_error
  end
end
