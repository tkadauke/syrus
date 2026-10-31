require "rails_helper"

RSpec.describe Coworkers::Create do
  class FakeCoworkerRemote
    attr_reader :repository, :seeded_files, :seeded_identity, :deleted_branches
    attr_accessor :branch_exists, :fail_access, :fail_seed, :delete_error

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
      ("a" * 40).tap { |sha| yield sha if block_given? }
    end

    def branch_sha(_branch) = "a" * 40

    def delete_if_matches!(branch, expected_sha:)
      raise delete_error if delete_error
      raise Coworkers::RemoteWorkspace::RefChanged, "changed" unless expected_sha == branch_sha(branch)

      deleted_branches << branch
      @branch_exists = false
    end
  end

  let(:owner) { Factories.user(first_name: "Ada", last_name: "Lovelace") }
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

    expect { create_service.call }.to raise_error(Coworkers::Create::CreationFailed, /cleanup completed: seed failed/)
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
    soul = remote.seeded_files.fetch("SOUL.md")
    expect(soul).to start_with("role: not set up yet\nname: Maya\n")
    expect(soul).to include(
      "name: Maya", "role: not set up yet", "Your name is Maya", "Interview Ada Lovelace"
    )
    expect(remote.seeded_files.fetch("USER.md")).to include("Your owner is Ada Lovelace")
    expect(remote.seeded_files.fetch("AGENTS.md")).to include(
      "append-oriented", "one entry per event", "@handle", "at most 64 KiB", Coworkers::PromptSection::TRUNCATION_MARKER
    )
    expect(remote.seeded_identity).to have_attributes(git_name: "Maya (@maya)", git_email: "maya@coworkers.syrus.invalid")
    expect(coworker).to have_attributes(accent_hex: "#0090FF", role_summary: "not set up yet")
    expect(coworker.grants.pluck(:capability, :approval_policy).to_h).to eq(described_class::DEFAULT_GRANTS)
    expect(coworker.grants.find_by!(capability: "chat.message_owner")).to have_attributes(approval_policy: "confirm")
    expect(coworker.coworker_chats.find_by!(role: "main").chat_session.repository).to eq(repository)
  end

  it "returns the completed coworker for duplicate delivery without duplicating records or branches" do
    key = "confirmation-42"
    allow(ChatTurnJob).to receive(:perform_later).and_call_original
    first = create_service(idempotency_key: key, about: "Engineer").call
    first_chat = first.chats.first
    first_message = first_chat.messages.find_by!(role: "system")
    expect(remote).not_to receive(:seed!)

    second = create_service(idempotency_key: key, about: "Engineer").call

    expect(second).to eq(first)
    expect(Coworkers::Coworker.where(handle: "maya").count).to eq(1)
    expect(Coworkers::ProvisioningAttempt.where(idempotency_key: key).count).to eq(1)
    expect(first_chat.messages.where(role: "system").count).to eq(1)
    expect(ChatTurnJob).to have_received(:perform_later).once.with(first_chat.id, first_message.id)
  end

  it "copies the complete coworker chat configuration to the main chat" do
    allow(owner).to receive(:chat_provider_configured?).with("codex").and_return(true)
    coworker = create_service(chat_provider: "codex", chat_model: "gpt-5.6-sol", chat_effort: "high").call

    expect(coworker.coworker_chats.find_by!(role: "main").chat_session).to have_attributes(
      chat_provider: "codex", chat_model: "gpt-5.6-sol", chat_effort: "high"
    )
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

  it "grants a different coworker owner write access to a shared repository" do
    repository_owner = Factories.user
    repository = Factories.repository(
      user: repository_owner, owner: "acme", name: "coworker-homes",
      polling_enabled: true, auto_merge_enabled: true, external_pr_ingestion_enabled: true
    )

    create_service.call

    expect(repository.repository_memberships.find_by!(user: owner)).to be_at_least("write")
    expect(repository.reload).to have_attributes(
      polling_enabled: true, auto_merge_enabled: true, external_pr_ingestion_enabled: true
    )
  end

  it "uses About for the soul and opens the chat with a configured-identity kickoff" do
    allow(ChatTurnJob).to receive(:perform_later).and_call_original

    coworker = create_service(about: "Research lead\nCurious and concise.").call
    chat = coworker.chats.first
    message = chat.messages.find_by!(role: "system")

    expect(remote.seeded_files.fetch("SOUL.md")).to eq("role: Research lead\nname: Maya\n\nResearch lead\nCurious and concise.\n")
    expect(remote.seeded_files.fetch("USER.md")).to include("Your owner is Ada Lovelace")
    expect(coworker.role_summary).to eq("Research lead")
    expect(message.extract_text_from_content).to include(
      "already described your identity in SOUL.md", "briefly greet your owner in your own voice",
      "small number of concrete questions", "If nothing is unclear"
    )
    expect(message.extract_text_from_content).not_to include("identity has not been set up yet")
    expect(chat.last_message_at).to eq(message.created_at)
    expect(ChatTurnJob).to have_received(:perform_later).with(chat.id, message.id)
  end

  it "opens the placeholder chat with a system kickoff that triggers the first turn" do
    allow(ChatTurnJob).to receive(:perform_later).and_call_original

    coworker = create_service.call
    chat = coworker.chats.first
    message = chat.messages.find_by!(role: "system")

    expect(message.extract_text_from_content).to eq(
      "You are Maya, and your owner is Ada Lovelace. Your identity has not been set up yet. " \
      "Interview your owner about your role, personality, working preferences, and boundaries, " \
      "then update your workspace identity files with the answers."
    )
    expect(ChatTurnJob).to have_received(:perform_later).with(chat.id, message.id)
  end

  it "deletes the pushed branch when database creation fails" do
    allow(Coworkers::Coworker).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(Coworkers::Coworker.new))

    expect { create_service.call }.to raise_error(Coworkers::Create::CreationFailed, /cleanup completed/)
    expect(remote.deleted_branches).to eq([ "coworkers/maya" ])
    expect(Repository.where(owner: "acme", name: "coworker-homes")).to be_empty
  end

  it "removes the real remote branch after a post-seed creation failure outside a Git repository" do
    Dir.mktmpdir("coworker-create-spec-") do |root|
      bare_remote = File.join(root, "coworker-homes.git")
      caller_directory = File.join(root, "not-a-repository")
      FileUtils.mkdir_p(caller_directory)
      GitRunner.new.run("init", "--bare", bare_remote)
      real_remote = Coworkers::RemoteWorkspace.new(owner: "acme", name: "coworker-homes", user: owner)
      allow(real_remote).to receive(:authenticated_url).and_return(bare_remote)
      creation_error = ActiveRecord::RecordInvalid.new(Coworkers::Coworker.new)
      allow(Coworkers::Coworker).to receive(:create!).and_raise(creation_error)
      service = described_class.new(
        owner: owner, name: "Maya", handle: "maya",
        workspace_repo: "https://github.com/acme/coworker-homes.git",
        remote_workspace: real_remote
      )

      expect { Dir.chdir(caller_directory) { service.call } }
        .to raise_error(Coworkers::Create::CreationFailed, /cleanup completed/)
      expect(real_remote.branch_exists?("coworkers/maya")).to be(false)
    end
  end

  it "raises the creation failure and redacts rollback failure diagnostics" do
    creation_error = ActiveRecord::RecordInvalid.new(Coworkers::Coworker.new)
    cleanup_error = GitRunner::GitError.new(
      [ "push", "https://x-access-token:secret-token@github.com/acme/coworker-homes.git" ],
      128,
      "fatal: unable to access 'https://x-access-token:secret-token@github.com/acme/coworker-homes.git'"
    )
    allow(Coworkers::Coworker).to receive(:create!).and_raise(creation_error)
    remote.delete_error = cleanup_error
    allow(Rails.logger).to receive(:error)

    expect { create_service.call }.to raise_error(Coworkers::Create::CreationFailed, /cleanup is pending/)

    expect(Rails.logger).to have_received(:error) do |message|
      expect(message).to include("durable cleanup pending", "GitRunner::GitError")
      expect(message).not_to include("secret-token")
    end
  end

  it "rolls back every record and deletes the branch when kickoff persistence fails" do
    allow_any_instance_of(ChatMessage).to receive(:record_chat_turn_state).and_raise(ActiveRecord::RecordInvalid.new(ChatMessage.new))

    expect { create_service.call }.to raise_error(Coworkers::Create::CreationFailed, /cleanup completed/)

    expect_creation_to_be_absent
  end

  it "rolls back every record and deletes the branch when kickoff enqueue fails" do
    allow(ChatTurnJob).to receive(:perform_later).and_return(false)

    expect { create_service(about: "Research lead").call }
      .to raise_error(Coworkers::Create::CreationFailed, /cleanup completed/)

    expect_creation_to_be_absent
  end

  def expect_creation_to_be_absent
    expect(remote.deleted_branches).to eq([ "coworkers/maya" ])
    expect(Coworkers::Coworker.where(handle: "maya")).to be_empty
    expect(Coworkers::Grant.count).to eq(0)
    expect(Coworkers::Chat.count).to eq(0)
    expect(ChatSession.where(user: owner, title: "Maya")).to be_empty
    expect(Handle.where(handle: "maya")).to be_empty
    expect(Repository.where(owner: "acme", name: "coworker-homes")).to be_empty
  end
end
