require "rails_helper"

RSpec.describe ChatGoal do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository, mode: "planning") }

  def goal_attrs(**attrs)
    {
      chat_session: chat,
      prompt: "Keep working until the release plan is ready."
    }.merge(attrs)
  end

  it "seeds ownership, repository, mode snapshot, and active slot from the chat" do
    goal = described_class.create!(goal_attrs)

    expect(goal.user).to eq(user)
    expect(goal.repository).to eq(repository)
    expect(goal.mode_snapshot).to include("mode" => "planning", "repository_id" => repository.id)
    expect(goal.active_slot).to eq("active")
  end

  it "enforces one resumable goal per chat" do
    described_class.create!(goal_attrs)
    duplicate = described_class.new(goal_attrs(prompt: "Do a second thing."))

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:active_slot]).to be_present
  end

  it "allows a new goal after the previous one is terminal" do
    described_class.create!(goal_attrs).complete!

    expect(described_class.create!(goal_attrs(prompt: "Next objective."))).to be_persisted
  end

  it "rejects auto job submission in planning mode" do
    goal = described_class.new(goal_attrs(auto_submit_jobs: true))

    expect(goal).not_to be_valid
    expect(goal.errors[:auto_submit_jobs]).to include("is only available in coding or local mode")
  end

  it "rejects auto proposal filing in coding mode" do
    chat.update!(mode: "coding")
    goal = described_class.new(goal_attrs(auto_file_proposals: true))

    expect(goal).not_to be_valid
    expect(goal.errors[:auto_file_proposals]).to include("is only available in planning mode")
  end

  it "keeps lifecycle methods idempotent" do
    goal = described_class.create!(goal_attrs)

    expect(goal.start!).to eq(true)
    expect(goal.pause!).to eq(true)
    expect(goal.pause!).to eq(true)
    expect(goal.resume!).to eq(true)
    expect(goal.complete!(reason: "done")).to eq(true)
    expect(goal.complete!(reason: "again")).to eq(true)
    expect(goal.resume!).to eq(false)

    expect(goal.reload).to have_attributes(
      status: "completed",
      terminal_reason: "done",
      active_slot: nil
    )
  end

  it "requires the goal user to own the chat" do
    other_user = Factories.user
    goal = described_class.new(goal_attrs(user: other_user))

    expect(goal).not_to be_valid
    expect(goal.errors[:user]).to include("must own the chat session")
  end
end
