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

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("Habit Tracker")
    expect(chat).not_to be_title_pending
    expect(chat.chat_provider).to eq("claude")
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

  it "does not overwrite an existing title" do
    chat.update!(title: "Existing title")
    called = false
    ChatTitleJob.agent_runner = ->(**_) {
      called = true
      result('{"title":"Replacement"}')
    }

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("Existing title")
    expect(called).to eq(false)
  end

  it "falls back to the repository name when generation fails" do
    ChatTitleJob.agent_runner = ->(**_) { result("not json") }

    described_class.perform_now(chat.id, message.id)

    expect(chat.reload.title).to eq("widgets")
  end
end
