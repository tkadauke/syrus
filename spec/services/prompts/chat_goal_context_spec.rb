require "rails_helper"

RSpec.describe Prompts::ChatGoalContext do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, mode: "planning") }

  it "requires direct evidence before marking the active goal complete" do
    chat_session.chat_goals.create!(
      prompt: "Remove untranslated user-visible copy.",
      completion_condition: "No untranslated user-visible strings remain."
    )

    prompt = described_class.new(chat_session: chat_session, current_message: nil).to_s

    expect(prompt).to include("re-read the goal prompt and completion_condition")
    expect(prompt).to include("independently verify them against current evidence")
    expect(prompt).to include("Do not treat Job/Epic summaries, PR titles, terminal states")
    expect(prompt).to include("another agent's verification summary as sufficient proof")
    expect(prompt).to include("inspect or run the relevant tests, audits, artifacts, live state, or source state yourself")
    expect(prompt).to include("allowlists, skipped checks, ignored paths, known-debt buckets")
    expect(prompt).to include("inspect those exceptions and decide whether they contradict the goal")
    expect(prompt).to include("cite the concrete evidence checked")
  end
end
