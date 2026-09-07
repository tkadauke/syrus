require "rails_helper"

RSpec.describe RuntimeSession, type: :model do
  let(:repository) { Factories.repository }

  def build_session(**attrs)
    described_class.create!({
      repository: repository,
      workspace_ref: "workspace-#{SecureRandom.hex(4)}",
      provider_key: "browser",
      display_name: "Browser"
    }.merge(attrs))
  end

  it "defaults to the starting state" do
    session = build_session
    expect(session.state).to eq("starting")
  end

  it "defaults capabilities and metadata to an empty hash" do
    session = build_session
    expect(session.capabilities).to eq({})
    expect(session.metadata).to eq({})
  end

  it "accepts all known states" do
    RuntimeSession::STATES.each do |state|
      session = described_class.new(
        repository: repository,
        workspace_ref: "workspace",
        provider_key: "browser",
        display_name: "Browser",
        state: state
      )
      expect(session).to be_valid
    end
  end

  it "rejects unknown states" do
    session = described_class.new(
      repository: repository,
      workspace_ref: "workspace",
      provider_key: "browser",
      display_name: "Browser",
      state: "materializing"
    )
    expect(session).not_to be_valid
  end

  it "requires workspace_ref, provider_key, and display_name" do
    session = described_class.new(repository: repository)
    expect(session).not_to be_valid
    expect(session.errors.attribute_names).to include(:workspace_ref, :provider_key, :display_name)
  end

  it "allows optional chat_session, job, workflow, and run associations" do
    session = build_session
    expect(session.chat_session).to be_nil
    expect(session.job).to be_nil
    expect(session.workflow).to be_nil
    expect(session.run).to be_nil
  end

  it "associates with a chat_session, job, workflow, and run when given" do
    job = Factories.job(repository: repository)
    chat = ChatSession.create!(user: repository.user)
    workflow = job.workflows.first
    run = job.runs.first

    session = build_session(chat_session: chat, job: job, workflow: workflow, run: run)

    expect(session.chat_session).to eq(chat)
    expect(session.job).to eq(job)
    expect(session.workflow).to eq(workflow)
    expect(session.run).to eq(run)
  end

  describe "#active?" do
    it "is true for non-terminal states" do
      expect(build_session(state: "running")).to be_active
    end

    it "is false for failed or stopped states" do
      expect(build_session(state: "failed")).not_to be_active
      expect(build_session(state: "stopped")).not_to be_active
    end
  end

  describe ".active scope" do
    it "excludes failed and stopped sessions" do
      running = build_session(state: "running")
      failed = build_session(state: "failed")
      stopped = build_session(state: "stopped")

      expect(described_class.active).to include(running)
      expect(described_class.active).not_to include(failed, stopped)
    end
  end

  describe ".primary scope" do
    it "returns only primary sessions" do
      primary = build_session(primary: true)
      secondary = build_session(primary: false)

      expect(described_class.primary).to include(primary)
      expect(described_class.primary).not_to include(secondary)
    end
  end

  describe ".for_provider scope" do
    it "filters by provider_key" do
      browser_session = build_session(provider_key: "browser")
      other_session = build_session(provider_key: "ios_simulator")

      expect(described_class.for_provider("browser")).to include(browser_session)
      expect(described_class.for_provider("browser")).not_to include(other_session)
    end
  end
end
