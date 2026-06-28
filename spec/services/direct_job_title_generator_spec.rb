require "rails_helper"

RSpec.describe DirectJobTitleGenerator do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  def result(final_text, **overrides)
    defaults = { turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", session_id: nil }
    AgentInvocation::Result.new(**defaults.merge(overrides), final_text: final_text)
  end

  def call_with(final_text, prompt: "Build a habit tracker", **overrides)
    runner = ->(**_) { result(final_text, **overrides) }
    described_class.call(prompt, user: user, repository: repository, agent_provider: "claude", runner: runner)
  end

  it "uses the title returned by the agent" do
    title = call_with('{"title":"Ruby Version Bump"}', prompt: "\n\nUpdate the Ruby version. Then run the checks.")

    expect(title).to eq("Ruby Version Bump")
  end

  it "passes the prompt and repository to the title prompt" do
    seen = {}
    runner = ->(**kwargs) {
      seen.merge!(kwargs)
      result('{"title":"Dashboard Filters"}')
    }

    title = described_class.call(
      "- `Tighten the dashboard filters`\n\nUse native validity for the form.",
      user: user,
      repository: repository,
      agent_provider: "claude",
      runner: runner
    )

    expect(title).to eq("Dashboard Filters")
    expect(seen[:prompt]).to include("Tighten the dashboard filters")
    expect(seen[:prompt]).to include("acme/widgets")
    expect(seen[:max_turns]).to eq(1)
  end

  it "cleans wrapping punctuation from the agent title" do
    title = call_with('{"title":"`Fix the login form`"}')

    expect(title).to eq("Fix the login form")
  end

  it "truncates long multibyte agent titles without invalid UTF-8" do
    title = call_with({ title: "#{"修" * 60} finish the dashboard" }.to_json)

    expect(title.bytesize).to be <= described_class::MAX_TITLE_BYTES
    expect(title).to be_valid_encoding
  end

  it "falls back when the agent cannot name the request" do
    expect(call_with('{"title":""}')).to eq("Direct job")
  end

  it "falls back without invoking the agent when credentials are missing" do
    user.update!(claude_oauth_token: nil)
    called = false
    runner = ->(**_) {
      called = true
      result('{"title":"Habit Tracker"}')
    }

    title = described_class.call(
      "Build a habit tracker",
      user: user,
      repository: repository,
      agent_provider: "claude",
      runner: runner
    )

    expect(title).to eq("Direct job")
    expect(called).to eq(false)
  end
end
