require "rails_helper"

RSpec.describe ChatTitleJob do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository, title: nil) }
  let(:message) { chat.messages.create!(role: "user", content: { "text" => "Build a habit tracker" }) }

  def result(final_text, **overrides)
    defaults = { turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", session_id: nil }
    AgentInvocation::Result.new(**defaults.merge(overrides), final_text: final_text)
  end

  before do
    ChatTitleJob.agent_runner = nil
  end

  after do
    ChatTitleJob.agent_runner = nil
  end

  it "enqueues on the low-priority maintenance queue" do
    expect {
      described_class.perform_later(chat.id, message.id)
    }.to have_enqueued_job(described_class).with(chat.id, message.id).on_queue("low_priority_maintenance")
  end

  it "stores the generated title once" do
    ChatTitleJob.agent_runner = ->(**_) { result('{"title":"Habit Tracker"}') }
    allow(OperationalLogging).to receive(:ingest)

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("Habit Tracker")
    expect(chat).not_to be_title_pending
    expect(chat.title_auto_fallback).to eq(false)
    expect(chat.chat_provider).to eq("claude")
    expect(OperationalLogging).to have_received(:ingest).with(
      level: "info",
      source: "chat_title_job",
      message: "ChatTitleJob success for chat #{chat.id}",
      context: hash_including(
        chat_session_id: chat.id,
        user_message_id: message.id,
        seed_source: "message_id",
        provider: "claude",
        status: "success",
        title_write: "generated",
        title_auto_fallback: false,
        elapsed_ms: be_a(Numeric)
      )
    )
  end

  it "uses the chat's pinned Codex provider when generating a title" do
    user.update!(agent_provider: "codex", codex_api_key: "sk-test", claude_oauth_token: nil)
    seen = {}
    ChatTitleJob.agent_runner = ->(**kwargs) {
      seen.merge!(kwargs)
      result('{"title":"Codex Habit Tracker"}')
    }

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("Codex Habit Tracker")
    expect(chat.chat_provider).to eq("codex")
    expect(seen[:api_key]).to eq("sk-test")
    expect(seen[:prompt]).to include("Build a habit tracker")
  end

  it "can generate a title from an explicit message text seed" do
    seen = {}
    ChatTitleJob.agent_runner = ->(**kwargs) {
      seen.merge!(kwargs)
      result('{"title":"Launch Planning"}')
    }

    described_class.perform_now(chat.id, nil, message_text: "plan launch")

    expect(chat.reload.title).to eq("Launch Planning")
    expect(seen[:prompt]).to include("plan launch")
  end

  it "does not overwrite an existing title" do
    chat.update!(title: "Existing title")
    allow(OperationalLogging).to receive(:ingest)
    called = false
    ChatTitleJob.agent_runner = ->(**_) {
      called = true
      result('{"title":"Replacement"}')
    }

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("Existing title")
    expect(called).to eq(false)
    expect(OperationalLogging).to have_received(:ingest).with(
      level: "info",
      source: "chat_title_job",
      message: "ChatTitleJob skipped for chat #{chat.id}",
      context: hash_including(
        chat_session_id: chat.id,
        user_message_id: message.id,
        seed_source: "message_id",
        provider: "claude",
        status: "skipped",
        title_write: "existing_title",
        title_auto_fallback: false,
        elapsed_ms: be_a(Numeric)
      )
    )
  end

  it "falls back to the repository name when generation fails" do
    ChatTitleJob.agent_runner = ->(**_) { result("not json") }
    allow(OperationalLogging).to receive(:ingest)

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("widgets")
    expect(chat.title_auto_fallback).to eq(true)
    expect(chat).not_to be_title_pending
    expect(OperationalLogging).to have_received(:ingest).with(
      level: "warn",
      source: "chat_title_job",
      message: "ChatTitleJob failure for chat #{chat.id}",
      context: hash_including(
        chat_session_id: chat.id,
        user_message_id: message.id,
        seed_source: "message_id",
        provider: "claude",
        status: "failure",
        failure_reason: a_string_including("invalid JSON"),
        problem_code: "validation_or_user_error",
        title_write: "fallback",
        title_auto_fallback: true,
        elapsed_ms: be_a(Numeric)
      )
    )
  end

  it "falls back to the current attached repository when generation fails" do
    first_repo = Factories.repository(user: user, owner: "acme", name: "api")
    current_repo = Factories.repository(user: user, owner: "acme", name: "web")
    attached_chat = ChatSession.create!(user: user, title: nil)
    attached_chat.chat_attachments.create!(attachable: first_repo)
    attached_chat.chat_attachments.create!(attachable: current_repo)
    attached_message = attached_chat.messages.create!(role: "user", content: { "text" => "Name this" })
    ChatTitleJob.agent_runner = ->(**_) { result("not json") }

    described_class.perform_now(attached_chat.id, attached_message.id)

    expect(attached_chat.reload.title).to eq("web")
    expect(attached_chat.title_auto_fallback).to eq(true)
    expect(attached_chat).not_to be_title_pending
  end

  it "retries generation when the stored title is a previous failed-generation fallback" do
    chat.update!(title: "widgets", title_auto_fallback: true)
    ChatTitleJob.agent_runner = ->(**_) { result('{"title":"Habit Tracker"}') }

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("Habit Tracker")
    expect(chat.title_auto_fallback).to eq(false)
  end

  it "does not overwrite a real title even if generation would succeed again" do
    chat.update!(title: "Existing title", title_auto_fallback: false)
    called = false
    ChatTitleJob.agent_runner = ->(**_) {
      called = true
      result('{"title":"Replacement"}')
    }

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("Existing title")
    expect(called).to eq(false)
  end
end
