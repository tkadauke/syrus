require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe ChatTitleGenerator do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }
  let(:workspace_root) { Pathname.new(Dir.mktmpdir("syrus-chat-title")) }

  before do
    allow(ChatWorkspace).to receive(:ensure_root!).with(chat).and_return(workspace_root)
  end

  after do
    FileUtils.rm_rf(workspace_root)
  end

  def result(final_text, **overrides)
    defaults = { turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", session_id: nil }
    AgentInvocation::Result.new(**defaults.merge(overrides), final_text: final_text)
  end

  def call_with(final_text, **overrides)
    runner = ->(**_) { result(final_text, **overrides) }
    described_class.new(chat_session: chat, message_text: "Build a habit tracker", runner: runner).call
  end

  it "parses a short JSON title from the agent" do
    generated = call_with('{"title":"Habit Tracker"}')

    expect(generated).to be_success
    expect(generated.title).to eq("Habit Tracker")
  end

  it "strips a surrounding JSON fence" do
    generated = call_with("```json\n{\"title\":\"Habit Tracker\"}\n```")

    expect(generated).to be_success
    expect(generated.title).to eq("Habit Tracker")
  end

  it "passes the first message and repository to the title prompt" do
    seen = {}
    runner = ->(**kwargs) {
      seen.merge!(kwargs)
      result('{"title":"Auth Map"}')
    }

    described_class.new(chat_session: chat, message_text: "Map the auth flow", runner: runner).call

    expect(seen[:prompt]).to include("Map the auth flow")
    expect(seen[:prompt]).to include("acme/widgets")
    expect(seen[:max_turns]).to eq(1)
  end

  it "rejects titles over sixty characters" do
    generated = call_with({ title: "A" * 61 }.to_json)

    expect(generated).not_to be_success
    expect(generated.error).to match(/title too long/)
  end

  it "returns failure when the agent cannot name the request" do
    generated = call_with('{"title":""}')

    expect(generated).not_to be_success
    expect(generated.error).to eq("empty title")
  end

  it "returns failure when Claude credentials are missing" do
    chat.user.update!(claude_oauth_token: nil)
    called = false
    runner = ->(**_) {
      called = true
      result('{"title":"Habit Tracker"}')
    }

    generated = described_class.new(chat_session: chat, message_text: "Build a habit tracker", runner: runner).call

    expect(generated).not_to be_success
    expect(generated.error).to eq("Claude credentials are missing")
    expect(called).to eq(false)
  end
end
