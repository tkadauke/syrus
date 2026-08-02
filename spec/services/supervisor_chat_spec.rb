require "rails_helper"

RSpec.describe SupervisorChat, type: :service do
  include ActiveJob::TestHelper

  let(:admin) { Factories.user(admin: true) }

  before { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }

  it "creates a pinned supervisor chat for an admin without repository attachment" do
    expect {
      @chat = described_class.ensure_for!(admin)
    }.to have_enqueued_job(ChatTurnJob).with(kind_of(Integer), kind_of(Integer)).on_queue("chat")

    chat = @chat

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

  it "seeds a supervisor operations kickoff message" do
    chat = described_class.ensure_for!(admin)
    kickoff = chat.messages.find_by!(role: "user")

    expect(kickoff.content).to include(
      "source" => "supervisor_kickoff",
      "text" => include("Start Supervisor operations triage")
    )
    expect(kickoff.content["text"]).to include("blocked work")
    expect(kickoff.content["text"]).to include("Jobs, Workflows, Runs, queues")
    expect(kickoff.content["text"]).to include("Do not treat missing repository attachment as a blocker")
    expect(kickoff.content["text"]).to include("ask for repository attachment only if I explicitly request code inspection")
    expect(chat.last_read_at).to eq(kickoff.created_at)
  end

  it "is idempotent for the same admin and does not duplicate kickoff turns" do
    first = described_class.ensure_for!(admin)

    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    second = described_class.ensure_for!(admin)

    expect(second.id).to eq(first.id)
    expect(admin.chat_sessions.where(system_kind: "supervisor").count).to eq(1)
    expect(second.messages.where(role: "user").count).to eq(1)
    expect(second.messages.find_by(role: "user").content["source"]).to eq("supervisor_kickoff")
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.select { |job| job[:job] == ChatTurnJob }).to be_empty
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
    expect(repaired.messages.find_by(role: "user").content["source"]).to eq("supervisor_kickoff")
  end
end
