require "rails_helper"

RSpec.describe Coworkers::Create do
  class FakeCoworkerRemote
    attr_reader :repository, :seeded_files, :seeded_identity, :deleted_branches
    attr_accessor :branch_exists, :fail_access, :fail_seed

    def initialize(user)
      @repository = Repository.new(owner: "acme", name: "coworker-homes", user: user)
      @deleted_branches = []
    end

    def branch_exists?(_branch) = branch_exists
    def test_push_access!
      raise "push denied" if fail_access
    end

    def seed!(branch:, files:, identity:)
      raise "seed failed" if fail_seed
      @seeded_branch = branch
      @seeded_files = files
      @seeded_identity = identity
    end

    def delete!(branch) = deleted_branches << branch
  end

  let(:owner) { Factories.user }
  let(:remote) { FakeCoworkerRemote.new(owner) }

  def create_service(**attributes)
    described_class.new(
      owner: owner, name: "Maya", handle: "maya",
      workspace_repo: "https://github.com/acme/coworker-homes.git",
      remote_workspace: remote, **attributes
    )
  end

  it "leaves no records or remote branch when handle validation fails" do
    Handle.create!(handle: "maya")

    expect { create_service.call }.to raise_error(ActiveRecord::RecordInvalid)
    expect(Coworkers::Coworker.count).to eq(0)
    expect(Repository.where(owner: "acme", name: "coworker-homes")).to be_empty
    expect(remote.seeded_files).to be_nil
  end

  it "rejects an existing home branch before testing push access" do
    remote.branch_exists = true
    expect(remote).not_to receive(:test_push_access!)

    expect { create_service.call }.to raise_error(Coworkers::Create::BranchExists, /coworkers\/maya/)
    expect(Coworkers::Coworker.count).to eq(0)
  end

  it "leaves nothing created when the push-access check fails" do
    remote.fail_access = true

    expect { create_service.call }.to raise_error("push denied")
    expect(Coworkers::Coworker.count).to eq(0)
    expect(Repository.where(owner: "acme", name: "coworker-homes")).to be_empty
  end

  it "rolls repository registration back when seeding fails" do
    remote.fail_seed = true

    expect { create_service.call }.to raise_error("seed failed")
    expect(Coworkers::Coworker.count).to eq(0)
    expect(Repository.where(owner: "acme", name: "coworker-homes")).to be_empty
  end

  it "seeds the orphan home and creates the coworker, defaults, and main chat" do
    coworker = create_service.call

    repository = Repository.find_by!(owner: "acme", name: "coworker-homes")
    expect(repository).to have_attributes(
      polling_enabled: false, auto_merge_enabled: false,
      external_pr_ingestion_enabled: false, main_branch_health_enabled: false
    )
    expect(remote.seeded_files).to include(
      ".gitattributes" => "memory/** merge=union\n",
      "memory/.gitkeep" => ""
    )
    expect(remote.seeded_files.fetch("SOUL.md")).to include("role: not set up yet", "Interview your owner")
    expect(remote.seeded_identity).to have_attributes(git_name: "Maya (@maya)", git_email: "maya@coworkers.syrus.invalid")
    expect(coworker).to have_attributes(color_key: Appearance::ColorPalette.default_key("maya"), role_summary: "not set up yet")
    expect(coworker.grants.pluck(:capability, :approval_policy).to_h).to eq(described_class::DEFAULT_GRANTS)
    expect(coworker.coworker_chats.find_by!(role: "main").chat_session.repository).to eq(repository)
  end

  it "reuses a shared repository without changing its automation flags" do
    repository = Factories.repository(
      user: owner, owner: "acme", name: "coworker-homes",
      polling_enabled: true, auto_merge_enabled: true, external_pr_ingestion_enabled: true
    )

    create_service.call

    expect(repository.reload).to have_attributes(
      polling_enabled: true, auto_merge_enabled: true, external_pr_ingestion_enabled: true
    )
    expect(Repository.where(owner: "acme", name: "coworker-homes").count).to eq(1)
  end

  it "uses About for the soul and skips the kickoff" do
    expect(ChatTurnJob).not_to receive(:perform_later)

    coworker = create_service(about: "Research lead\nCurious and concise.").call

    expect(remote.seeded_files.fetch("SOUL.md")).to eq("role: Research lead\n\nResearch lead\nCurious and concise.\n")
    expect(coworker.role_summary).to eq("Research lead")
    expect(coworker.chats.first.messages).to be_empty
  end

  it "opens the placeholder chat with a system kickoff that triggers the first turn" do
    allow(ChatTurnJob).to receive(:perform_later)

    coworker = create_service.call
    chat = coworker.chats.first
    message = chat.messages.find_by!(role: "system")

    expect(message.extract_text_from_content).to include("Interview your owner now")
    expect(ChatTurnJob).to have_received(:perform_later).with(chat.id, message.id)
  end

  it "deletes the pushed branch when database creation fails" do
    allow(Coworkers::Coworker).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(Coworkers::Coworker.new))

    expect { create_service.call }.to raise_error(ActiveRecord::RecordInvalid)
    expect(remote.deleted_branches).to eq([ "coworkers/maya" ])
    expect(Repository.where(owner: "acme", name: "coworker-homes")).to be_empty
  end
end
