require "rails_helper"
require Rails.root.join("db/migrate/20260624135815_create_chat_wakeups")

RSpec.describe CreateChatWakeups do
  it "is idempotent when run more than once" do
    migration = described_class.new

    expect {
      migration.up
      migration.up
    }.not_to raise_error
  end
end
