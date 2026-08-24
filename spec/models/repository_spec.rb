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

  it "defaults review_policy to 'self' and accepts other valid policies" do
    repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
    expect(repo.review_policy).to eq("self")

    repo.update!(review_policy: "two_person")
    expect(repo.review_policy).to eq("two_person")

    repo.update!(review_policy: "final_say")
    expect(repo.review_policy).to eq("final_say")
  end

  it "defaults Epic dependency policy to linear and accepts nonlinear" do
    repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
    expect(repo.epic_dependency_policy).to eq("linear")

    repo.update!(epic_dependency_policy: "nonlinear")
    expect(repo.epic_dependency_policy).to eq("nonlinear")
  end

  it "rejects unknown Epic dependency policies" do
    repo = Repository.new(user: owner, owner: "acme", name: "widgets", epic_dependency_policy: "mesh")
    expect(repo).not_to be_valid
    expect(repo.errors[:epic_dependency_policy]).to be_present
  end

  it "rejects unknown review policies" do
    repo = Repository.new(user: owner, owner: "acme", name: "widgets", review_policy: "committee")
    expect(repo).not_to be_valid
    expect(repo.errors[:review_policy]).to be_present
  end

  it "has_many final_approvers through repository_final_approvers" do
    repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
    approver = Factories.user
    RepositoryFinalApprover.create!(repository: repo, user: approver)
    expect(repo.final_approvers).to contain_exactly(approver)
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

  describe "#effective_agent_provider with user context" do
    let(:repo) { Repository.create!(user: owner, owner: "acme", name: "widgets") }
    let(:member) { Factories.user(agent_provider: "claude") }

    it "returns membership agent_provider when the user has one set on a write-tier membership" do
      repo.repository_memberships.create!(user: member, role: "write", agent_provider: "codex")
      expect(repo.effective_agent_provider(user: member)).to eq("codex")
    end

    it "ignores a read-tier membership's agent_provider override" do
      repo.repository_memberships.create!(user: member, role: "read", agent_provider: "codex")
      expect(repo.effective_agent_provider(user: member)).to eq("claude")
    end

    it "falls back to repo-level agent_provider when membership has none" do
      repo.update!(agent_provider: "codex")
      repo.repository_memberships.create!(user: member, role: "read")
      expect(repo.effective_agent_provider(user: member)).to eq("codex")
    end

    it "falls back to the user's default agent_provider when both membership and repo have none" do
      repo.repository_memberships.create!(user: member, role: "read")
      expect(repo.effective_agent_provider(user: member)).to eq("claude")
    end

    it "returns repo-level provider without a user argument" do
      repo.update!(agent_provider: "codex")
      expect(repo.effective_agent_provider).to eq("codex")
    end

    it "normalizes blank membership agent_provider to nil and falls through" do
      repo.repository_memberships.create!(user: member, role: "write", agent_provider: "")
      expect(repo.effective_agent_provider(user: member)).to eq("claude")
    end
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

  it "records optional upstream repository metadata" do
    repo = Repository.create!(
      user: owner,
      owner: "acme",
      name: "widgets",
      upstream_owner: "rails",
      upstream_name: "rails",
      upstream_default_branch: "main"
    )

    expect(repo.upstream_slug).to eq("rails/rails")
    expect(repo.upstream_default_branch).to eq("main")
  end

  it "normalizes blank upstream metadata without changing existing repositories" do
    repo = Repository.create!(
      user: owner,
      owner: "acme",
      name: "widgets",
      upstream_owner: "",
      upstream_name: "",
      upstream_default_branch: ""
    )

    expect(repo.upstream_owner).to be_nil
    expect(repo.upstream_name).to be_nil
    expect(repo.upstream_default_branch).to be_nil
    expect(repo.upstream_slug).to be_nil
  end

  it "rejects incomplete or malformed upstream targets" do
    incomplete = Repository.new(user: owner, owner: "acme", name: "widgets", upstream_owner: "rails")
    expect(incomplete).not_to be_valid
    expect(incomplete.errors[:upstream_owner]).to be_present

    malformed = Repository.new(user: owner, owner: "acme", name: "widgets", upstream_owner: "bad owner", upstream_name: "rails")
    expect(malformed).not_to be_valid
    expect(malformed.errors[:upstream_owner]).to be_present
  end

  it "enforces global uniqueness on (owner, name)" do
    Repository.create!(user: owner, owner: "acme", name: "widgets")
    dup = Repository.new(user: owner, owner: "acme", name: "widgets")
    expect(dup).not_to be_valid
    expect(dup.errors[:name]).to include("has already been registered for this GitHub owner")
  end

  it "rejects the same repo even under a different user — repos are globally unique by [owner, name]" do
    Repository.create!(user: owner, owner: "acme", name: "widgets")
    other = Factories.user
    twin = Repository.new(user: other, owner: "acme", name: "widgets")
    expect(twin).not_to be_valid
    expect(twin.errors[:name]).to include("has already been registered for this GitHub owner")
  end

  it "allows the same owner to have different repo names" do
    Repository.create!(user: owner, owner: "acme", name: "widgets")
    other = Repository.new(user: owner, owner: "acme", name: "gadgets")
    expect(other).to be_valid
  end

  describe "repository_memberships" do
    it "can have multiple members through memberships" do
      repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
      collaborator = Factories.user
      repo.repository_memberships.create!(user: collaborator, role: "read")

      expect(repo.members).to include(owner, collaborator)
    end

    it "enforces unique membership per user per repository" do
      repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
      dup = repo.repository_memberships.build(user: owner, role: "read")
      expect(dup).not_to be_valid
      expect(dup.errors[:user_id]).to be_present
    end

    it "rejects unknown roles" do
      repo = Repository.create!(user: owner, owner: "acme", name: "widgets")
      bad = repo.repository_memberships.build(user: owner, role: "superadmin")
      expect(bad).not_to be_valid
      expect(bad.errors[:role]).to be_present
    end
  end

  describe "upstream_repository association" do
    it "links a fork to its upstream via upstream_repository_id" do
      upstream = Repository.create!(user: owner, owner: "rails", name: "rails")
      fork = Repository.create!(user: owner, owner: "acme", name: "rails", upstream_repository: upstream)

      expect(fork.upstream_repository).to eq(upstream)
      expect(upstream.fork_repositories).to include(fork)
    end

    it "upstream_repository is optional" do
      repo = Repository.new(user: owner, owner: "acme", name: "widgets")
      expect(repo).to be_valid
    end
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

    it "builds an authenticated_url from the user's GithubClient token" do
      user = Factories.user
      client = instance_double(GithubClient, access_token: "ghs_fresh")
      allow(GithubClient).to receive(:for).with(repository: repo, user: user).and_return(client)

      expect(repo.authenticated_url(user: user)).to eq(
        "https://x-access-token:ghs_fresh@github.com/acme/widgets.git"
      )
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

  describe "#effective_role_for" do
    let(:repo) { Factories.repository(user: owner) }
    let(:global_admin) { Factories.user(admin: true) }
    let(:direct_reader) { Factories.user }
    let(:team_writer) { Factories.user }
    let(:both) { Factories.user }
    let(:stranger) { Factories.user }
    let(:team) { Team.create!(name: "Platform") }

    before do
      repo.repository_memberships.create!(user: direct_reader, role: "read")
      repo.repository_memberships.create!(user: both, role: "read")
      team.team_memberships.create!(user: team_writer, role: "member")
      team.team_memberships.create!(user: both, role: "member")
      team.team_repositories.create!(repository: repo, role: "write")
    end

    it "returns 'admin' for a global admin regardless of membership" do
      expect(repo.effective_role_for(global_admin)).to eq("admin")
    end

    it "returns the direct RepositoryMembership role when there is no team grant" do
      expect(repo.effective_role_for(direct_reader)).to eq("read")
    end

    it "returns the best TeamRepository role for a user with only a team grant" do
      expect(repo.effective_role_for(team_writer)).to eq("write")
    end

    it "returns the higher of a direct membership and a team grant for the same user" do
      expect(repo.effective_role_for(both)).to eq("write")
    end

    it "returns nil for a user with no direct membership and no team grant" do
      expect(repo.effective_role_for(stranger)).to be_nil
    end

    it "returns nil for a nil user" do
      expect(repo.effective_role_for(nil)).to be_nil
    end

    # Proves teams are purely additive: a repository with zero
    # TeamRepository grants behaves identically to the
    # direct-membership-only model that preceded teams.
    it "matches the direct-membership-only outcome when the repo has no team grants" do
      bare_repo = Factories.repository(user: owner)
      bare_repo.repository_memberships.create!(user: direct_reader, role: "read")

      expect(bare_repo.effective_role_for(direct_reader)).to eq(bare_repo.membership_for(direct_reader).role)
      expect(bare_repo.effective_role_for(stranger)).to be_nil
      expect(bare_repo.effective_role_for(global_admin)).to eq("admin")
    end
  end

  describe "#member_at_least?" do
    let(:repo) { Factories.repository(user: owner) }
    let(:team) { Team.create!(name: "Platform") }
    let(:team_admin) { Factories.user }

    before do
      team.team_memberships.create!(user: team_admin, role: "member")
      team.team_repositories.create!(repository: repo, role: "admin")
    end

    it "is true when a team grant meets the tier" do
      expect(repo.member_at_least?(team_admin, "write")).to be true
    end

    it "is false when neither direct membership nor a team grant meets the tier" do
      expect(repo.member_at_least?(Factories.user, "read")).to be false
    end
  end

  describe ".accessible_repository_ids_for" do
    it "includes repositories granted via a team, alongside direct memberships" do
      direct_repo = Factories.repository(user: owner)
      team_repo = Factories.repository(user: owner)
      unrelated_repo = Factories.repository(user: owner)
      user = Factories.user
      direct_repo.repository_memberships.create!(user: user, role: "read")
      team = Team.create!(name: "Platform")
      team.team_memberships.create!(user: user, role: "member")
      team.team_repositories.create!(repository: team_repo, role: "read")

      ids = Repository.accessible_repository_ids_for(user).pluck(:id)

      expect(ids).to contain_exactly(direct_repo.id, team_repo.id)
      expect(ids).not_to include(unrelated_repo.id)
    end

    it "returns none for a nil user" do
      Factories.repository
      expect(Repository.accessible_repository_ids_for(nil)).to be_empty
    end
  end

  describe ".accessible_to" do
    it "includes repositories the user owns" do
      owner = Factories.user
      owned = Factories.repository(user: owner)

      expect(Repository.accessible_to(owner)).to include(owned)
    end

    it "includes repositories where the user has a RepositoryMembership" do
      owner = Factories.user(email_address: "owner@example.com")
      collaborator = Factories.user(email_address: "collaborator@example.com")
      shared_repo = Factories.repository(user: owner)
      shared_repo.repository_memberships.create!(user: collaborator, role: "read")

      expect(Repository.accessible_to(collaborator)).to include(shared_repo)
    end

    it "excludes repositories the user neither owns nor is a member of" do
      owner = Factories.user(email_address: "owner2@example.com")
      unrelated_user = Factories.user(email_address: "unrelated@example.com")
      other_repo = Factories.repository(user: owner)

      expect(Repository.accessible_to(unrelated_user)).not_to include(other_repo)
    end
  end
end
