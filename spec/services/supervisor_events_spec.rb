require "rails_helper"

RSpec.describe SupervisorEvents, type: :service do
  include ActiveJob::TestHelper

  let!(:feature) do
    Feature.find_or_create_by!(slug: "admin_supervisor_chat") do |record|
      record.category = "Operations"
      record.name = "Admin supervisor chat"
      record.enabled = false
    end
  end
  let!(:admin) { Factories.user(admin: true) }
  let!(:other_admin) { Factories.user(admin: true) }
  let!(:non_admin) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: admin) }

  before do
    feature.update!(enabled: false)
    Feature.clear_enabled_cache!("admin_supervisor_chat")
    allow(AppEvents).to receive(:broadcast)
  end

  def enable_supervisor_chat!
    feature.update!(enabled: true)
    Feature.clear_enabled_cache!("admin_supervisor_chat")
  end

  it "no-ops while admin_supervisor_chat is disabled" do
    result = nil
    expect {
      result = described_class.publish!(
        kind: "job_failed",
        severity: "critical",
        subject: "Job failed",
        repository: repository,
        actor: admin,
        summary: "JOB-1 failed",
        details: { "job_id" => 1 },
        dedupe_key: "job_failed:1"
      )
    }.not_to change(ChatMessage, :count)
    expect(result).to eq([])
    expect(ChatScopedEvent.count).to eq(0)

    expect(ChatSession.where(system_kind: "supervisor")).to be_empty
  end

  it "creates scoped events and evaluator jobs for every admin supervisor chat" do
    enable_supervisor_chat!
    job = Factories.job_record(user: admin, repository: repository, issue_number: 12, issue_title: "Repair main")

    events = described_class.publish!(
      kind: "main_broken",
      severity: "critical",
      subject: "Main branch broken",
      repository: repository,
      job: job,
      actor: admin,
      summary: "CI failed at abc123",
      details: { "sha" => "abc123" },
      dedupe_key: "main_broken:#{repository.id}:abc123"
    )

    expect(events.size).to eq(2)
    expect(ChatScopedEvent.count).to eq(2)
    expect(non_admin.chat_sessions.where(system_kind: "supervisor")).to be_empty

    chat = admin.chat_sessions.find_by!(system_kind: "supervisor")
    scoped_event = ChatScopedEvent.find_by!(chat_session: chat)
    expect(scoped_event).to have_attributes(
      source_kind: "main_broken",
      delivery_state: "pending",
      dedupe_key: "main_broken:#{repository.id}:abc123",
      repository_id: repository.id,
      job_id: job.id,
      chat_message_id: nil
    )
    expect(scoped_event.delivered_at).to be_nil
    expect(scoped_event.payload).to include(
      "kind" => "main_broken",
      "severity" => "critical",
      "summary" => "CI failed at abc123"
    )
    expect(scoped_event.payload["repository"]).to include(
      "id" => repository.id,
      "slug" => repository.slug
    )
    expect(chat.messages).to be_empty
    expect(ChatScopedEventEvaluatorJob).to have_been_enqueued.with(scoped_event.id, chat.id)
  end

  it "dedupes repeated events with the same key in recent supervisor history" do
    enable_supervisor_chat!

    2.times do
      described_class.publish!(
        kind: "main_broken",
        severity: "critical",
        subject: "Main branch broken",
        repository: repository,
        actor: admin,
        summary: "CI failed at abc123",
        dedupe_key: "main_broken:#{repository.id}:abc123"
      )
    end

    expect(admin.chat_sessions.find_by!(system_kind: "supervisor").messages.count).to eq(0)
    expect(other_admin.chat_sessions.find_by!(system_kind: "supervisor").messages.count).to eq(0)
    expect(admin.chat_sessions.find_by!(system_kind: "supervisor").scoped_events.count).to eq(1)
    expect(other_admin.chat_sessions.find_by!(system_kind: "supervisor").scoped_events.count).to eq(1)
  end

  it "enqueues evaluator jobs instead of chat turns for scoped supervisor event delivery" do
    enable_supervisor_chat!

    expect {
      described_class.publish!(
        kind: "job_failed",
        severity: "critical",
        subject: "Job failed",
        repository: repository,
        actor: admin,
        summary: "The workflow failed.",
        dedupe_key: "job_failed:1"
      )
    }.not_to have_enqueued_job(ChatTurnJob)
    expect(ChatScopedEventEvaluatorJob).to have_been_enqueued.exactly(2).times
  end

  it "marks supervisor chats unread and broadcasts a chat sidebar update" do
    enable_supervisor_chat!
    chat = SupervisorChat.ensure_for!(admin)
    chat.update!(last_message_at: 1.hour.ago, last_read_at: Time.current)

    described_class.publish!(
      kind: "job_implemented",
      severity: "info",
      subject: "Job implemented",
      repository: repository,
      actor: admin,
      summary: "PR opened",
      dedupe_key: "job_implemented:1"
    )

    chat.reload
    expect(chat.last_read_at).to be_nil
    expect(chat.last_message_at).to be > 1.minute.ago
    expect(AppEvents).to have_received(:broadcast).with(
      user: admin,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "last_message_at", "last_read_at", "supervisor_event" ]
    )
  end
end
