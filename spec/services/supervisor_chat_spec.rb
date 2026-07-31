require "rails_helper"

RSpec.describe SupervisorChat, type: :service do
  let(:admin) { Factories.user(admin: true) }

  it "creates a pinned supervisor chat for an admin without repository attachment" do
    chat = described_class.ensure_for!(admin)

    expect(chat).to have_attributes(
      user_id: admin.id,
      system_kind: "supervisor",
      title: "Supervisor",
      pinned: true,
      hidden_at: nil
    )
    expect(chat.last_message_at).to be_present
    expect(chat.chat_attachments).to be_empty
  end

  it "is idempotent for the same admin" do
    first = described_class.ensure_for!(admin)
    second = described_class.ensure_for!(admin)

    expect(second.id).to eq(first.id)
    expect(admin.chat_sessions.where(system_kind: "supervisor").count).to eq(1)
  end

  it "rejects non-admin users" do
    admin
    non_admin = Factories.user(admin: false)

    expect { described_class.ensure_for!(non_admin) }
      .to raise_error(ArgumentError, "Supervisor chat requires an admin user")
  end

  it "repairs the durable affordance if an existing supervisor chat drifted while disabled" do
    chat = ChatSession.create!(
      user: admin,
      system_kind: "supervisor",
      title: "Old",
      pinned: false,
      hidden_at: 1.hour.ago,
      last_message_at: nil
    )

    repaired = described_class.ensure_for!(admin)

    expect(repaired.id).to eq(chat.id)
    expect(repaired).to have_attributes(title: "Supervisor", pinned: true, hidden_at: nil)
    expect(repaired.last_message_at).to be_present
  end
end
