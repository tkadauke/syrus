require "rails_helper"

RSpec.describe Repository do
  let(:owner) { Factories.user }

  it "creates with valid attributes and applies defaults" do
    repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
    expect(repo).to be_persisted
    expect(repo.default_branch).to eq("main")
    expect(repo.polling_enabled).to be true
    expect(repo.trigger_label).to eq("syrus")
    expect(repo.agent_provider).to be_nil
  end

  it "allows a repository-level default agent override" do
    repo = Repository.create!(user: owner, owner: "acme", name: "widgets", agent_provider: "codex")
    expect(repo.agent_provider).to eq("codex")
  end

  it "defaults auto-approval to never and accepts grader-gated modes" do
    repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
    expect(repo.auto_approve_mode).to eq("never")

    repo.update!(auto_approve_mode: "if_graders_pass")
    expect(repo.auto_approve_mode).to eq("if_graders_pass")
  end

  it "rejects unknown auto-approval modes" do
    repo = Repository.new(user: owner, owner: "acme", name: "widgets", auto_approve_mode: "whenever")
    expect(repo).not_to be_valid
    expect(repo.errors[:auto_approve_mode]).to be_present
  end

  it "normalizes blank agent_provider to user-default fallback" do
    owner.update!(agent_provider: "codex", codex_api_key: "sk-test")
    repo = Repository.create!(user: owner, owner: "acme", name: "widgets", agent_provider: "")
    expect(repo.agent_provider).to be_nil
    expect(repo.effective_agent_provider).to eq("codex")
  end

  it "rejects unknown repository agent providers" do
    repo = Repository.new(user: owner, owner: "acme", name: "widgets", agent_provider: "oracle")
    expect(repo).not_to be_valid
    expect(repo.errors[:agent_provider]).to be_present
  end

  it "rejects malformed owner/name strings" do
    invalid = Repository.new(user: owner, owner: "bad owner", name: "ok")
    expect(invalid).not_to be_valid
    expect(invalid.errors[:owner]).to be_present
  end

  it "enforces uniqueness on (user, owner, name)" do
    Repository.create!(user: owner, owner: "acme", name: "widgets")
    dup = Repository.new(user: owner, owner: "acme", name: "widgets")
    expect(dup).not_to be_valid
    expect(dup.errors[:owner]).to be_present
  end

  it "allows the same repo under a different user" do
    Repository.create!(user: owner, owner: "acme", name: "widgets")
    other = Factories.user
    twin = Repository.new(user: other, owner: "acme", name: "widgets")
    expect(twin).to be_valid
  end

  it "links to an active GitHub App installation for the owner" do
    installation = Installation.create!(
      user: owner,
      github_installation_id: 987,
      account_login: "Acme",
      account_id: 123,
      account_type: "Organization",
      installed_at: Time.current
    )

    repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
    expect(repo.installation).to eq(installation)
  end

  it "exposes a slug" do
    repo = Repository.new(owner: "acme", name: "widgets")
    expect(repo.slug).to eq("acme/widgets")
  end

  describe "remote URLs" do
    let(:repo) { Repository.new(owner: "acme", name: "widgets") }

    it "exposes an anonymous remote_url safe to bake into a saved clone" do
      expect(repo.remote_url).to eq("https://github.com/acme/widgets.git")
    end

    it "builds a token-bearing push URL per call (so the token never lands on disk)" do
      expect(repo.authenticated_push_url("ghp_secret")).to eq(
        "https://x-access-token:ghp_secret@github.com/acme/widgets.git"
      )
    end

    it "keeps the token out of remote_url" do
      expect(repo.remote_url).not_to include("ghp_")
      expect(repo.remote_url).not_to include("x-access-token")
    end
  end

  describe "archive lifecycle" do
    let(:repo) { Factories.repository(user: owner, polling_enabled: true) }

    it "starts active (archived_at: nil)" do
      expect(repo).not_to be_archived
      expect(Repository.active).to include(repo)
      expect(Repository.archived).not_to include(repo)
    end

    it "archive! stamps archived_at and turns off polling" do
      freeze_time do
        repo.archive!
        expect(repo.archived_at).to eq(Time.current)
        expect(repo.polling_enabled).to be false
        expect(repo).to be_archived
      end
    end

    it "archive! moves the repo from active to archived scope" do
      repo.archive!
      expect(Repository.active).not_to include(repo)
      expect(Repository.archived).to include(repo)
    end

    it "unarchive! clears archived_at but does NOT auto-resume polling" do
      repo.archive!
      repo.unarchive!
      expect(repo.archived_at).to be_nil
      expect(repo).not_to be_archived
      expect(repo.polling_enabled).to be false   # stays off — user re-enables explicitly
    end
  end
end
