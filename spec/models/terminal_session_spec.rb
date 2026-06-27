require "rails_helper"

RSpec.describe TerminalSession, type: :model do
  let(:user) { Factories.user }
  let(:base_attrs) do
    {
      user: user,
      name: "scratch",
      working_directory: Rails.root.to_s,
      started_at: Time.current
    }
  end

  it "validates required fields" do
    terminal_session = described_class.new

    expect(terminal_session).not_to be_valid
    expect(terminal_session.errors[:user]).to include("must exist")
    expect(terminal_session.errors[:name]).to include("can't be blank")
    expect(terminal_session.errors[:working_directory]).to include("can't be blank")
    expect(terminal_session.errors[:started_at]).to include("can't be blank")
  end

  it "allows the supported terminal outcomes" do
    described_class::OUTCOMES.each do |outcome|
      terminal_session = described_class.new(base_attrs.merge(outcome: outcome))

      expect(terminal_session).to be_valid
    end
  end

  it "rejects unknown outcomes" do
    terminal_session = described_class.new(base_attrs.merge(outcome: "timed_out"))

    expect(terminal_session).not_to be_valid
    expect(terminal_session.errors[:outcome]).to include("is not included in the list")
  end

  it "can belong to a workflow" do
    workflow = Factories.job(user: user).workflows.first

    terminal_session = described_class.create!(base_attrs.merge(workflow: workflow))

    expect(terminal_session.workflow).to eq(workflow)
  end

  it "generates a 32-byte hex auth token before create" do
    terminal_session = described_class.create!(base_attrs)

    expect(terminal_session.auth_token).to match(/\A\h{64}\z/)
  end

  it "does not replace an explicit auth token" do
    terminal_session = described_class.create!(base_attrs.merge(auth_token: "explicit-token"))

    expect(terminal_session.auth_token).to eq("explicit-token")
  end

  it "exposes running and finished scopes and predicates" do
    running = described_class.create!(base_attrs)
    finished = described_class.create!(
      base_attrs.merge(name: "done", finished_at: Time.current, outcome: "exited")
    )

    expect(described_class.running).to contain_exactly(running)
    expect(described_class.finished).to contain_exactly(finished)
    expect(running).to be_running
    expect(finished).to be_finished
  end

  it "reports relay readiness from relay_address" do
    terminal_session = described_class.new(base_attrs)

    expect(terminal_session).not_to be_relay_ready

    terminal_session.relay_address = "127.0.0.1:4444"

    expect(terminal_session).to be_relay_ready
  end
end
