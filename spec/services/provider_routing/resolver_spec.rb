require "rails_helper"

RSpec.describe ProviderRouting::Resolver do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before do
    allow(AgentProviders.for("claude")).to receive(:available_models).and_return([])
    allow(AgentProviders.for("codex")).to receive(:available_models).and_return([])
  end

  def resolve(job, task_key: "ci_failure")
    described_class.call(job: job, task_key: task_key)
  end

  def candidate(provider:, model: nil, effort_level: nil)
    described_class::Candidate.new(provider: provider, model: model, effort_level: effort_level)
  end

  describe "1. job explicit override" do
    it "returns a single candidate built from the job's own provider/model/effort_level, ignoring every rule" do
      ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "ci_failure", candidates: [ { "provider" => "codex" } ])

      job = Factories.job(
        repository: repository,
        user: user,
        job_provider_setting: "claude",
        agent_provider: "claude",
        model: "sonnet",
        effort_level: "high"
      )

      expect(resolve(job)).to eq([ candidate(provider: "claude", model: "sonnet", effort_level: "high") ])
    end

    it "does not apply when job_provider_setting is the default sentinel" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      expect(resolve(job)).to eq(described_class::HARDCODED_FALLBACK)
    end

    it "uses the pinned job_provider_setting once an operator repins the job" do
      # switch_job_provider_setting! keeps the presentation column in sync, but
      # ProviderRouting::Resolver still resolves through workflow_agent_provider
      # so job_provider_setting remains the source of truth for the override.
      job = Factories.job(
        repository: repository,
        user: user,
        job_provider_setting: "claude",
        agent_provider: "claude",
        model: "sonnet",
        effort_level: "high"
      )

      job.switch_job_provider_setting!("codex")

      expect(job.agent_provider).to eq("codex")
      expect(resolve(job)).to eq([ candidate(provider: "codex") ])
    end
  end

  describe "2. repository rule, exact task_key" do
    it "wins over the repository's default-task rule and every user-scoped rule" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "default", candidates: [ { "provider" => "codex" } ])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "ci_failure", candidates: [ { "provider" => "agy" } ])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "agy" } ])
      ProviderRoutingRule.create!(
        scope_type: "repository",
        scope_id: repository.id,
        task_key: "ci_failure",
        candidates: [ { "provider" => "claude", "model" => "sonnet" }, { "provider" => "codex" } ]
      )

      expect(resolve(job)).to eq([
        candidate(provider: "claude", model: "sonnet"),
        candidate(provider: "codex")
      ])
    end
  end

  describe "3. repository rule, default task_key" do
    it "is used when no exact-task_key repository rule exists, and wins over user-scoped rules" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "ci_failure", candidates: [ { "provider" => "agy" } ])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "agy" } ])
      ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "default", candidates: [ { "provider" => "codex" } ])

      expect(resolve(job)).to eq([ candidate(provider: "codex") ])
    end
  end

  describe "4. user rule, exact task_key" do
    it "is used when neither repository rule exists, and wins over the user's default-task rule" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "codex" } ])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "ci_failure", candidates: [ { "provider" => "agy" } ])

      expect(resolve(job)).to eq([ candidate(provider: "agy") ])
    end
  end

  describe "5. user rule, default task_key" do
    it "is used when no more specific rule exists at any scope" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "agy" } ])

      expect(resolve(job)).to eq([ candidate(provider: "agy") ])
    end
  end

  describe "6. hardcoded fallback" do
    it "returns a single claude candidate when no override or rule applies at any scope" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      expect(resolve(job)).to eq([ candidate(provider: "claude") ])
    end

    it "ignores rules scoped to a different repository or user" do
      other_user = Factories.user
      other_repository = Factories.repository(user: other_user)
      ProviderRoutingRule.create!(scope_type: "repository", scope_id: other_repository.id, task_key: "default", candidates: [ { "provider" => "codex" } ])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: other_user.id, task_key: "default", candidates: [ { "provider" => "agy" } ])

      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      expect(resolve(job)).to eq(described_class::HARDCODED_FALLBACK)
    end
  end

  describe "task_key scoping" do
    it "is keyed per task -- a rule for one task_key does not leak into a resolve for a different task_key" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")
      ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "rebase", candidates: [ { "provider" => "codex" } ])

      expect(resolve(job, task_key: "pr_comment")).to eq(described_class::HARDCODED_FALLBACK)
      expect(resolve(job, task_key: "rebase")).to eq([ candidate(provider: "codex") ])
    end
  end

  describe "user scope resolution" do
    it "resolves the user-scoped rule against the job's owner_user, not the creating user, when they differ" do
      owner = Factories.user
      job = Factories.job(repository: repository, user: user, owner_user: owner, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: owner.id, task_key: "default", candidates: [ { "provider" => "agy" } ])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "codex" } ])

      expect(resolve(job)).to eq([ candidate(provider: "agy") ])
    end
  end

  describe "explicit repository provider vs. user-scoped routing rules" do
    # JOB-5393 / WF-29556: a repository configured with an explicit
    # agent_provider (the real-world story used "muse"; these specs use
    # "codex" as a stand-in registered provider) must not be quietly routed
    # to a user's personal default-routing-rule provider.
    it "puts the repository's explicit agent_provider ahead of a user-scoped default routing rule" do
      repository.update!(agent_provider: "codex")
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "claude" } ])

      expect(resolve(job)).to eq([
        candidate(provider: "codex"),
        candidate(provider: "claude")
      ])
    end

    it "keeps the user-scoped rule's candidates as a failover chain behind the repository provider" do
      repository.update!(agent_provider: "codex")
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "ci_failure", candidates: [ { "provider" => "claude" }, { "provider" => "agy" } ])

      expect(resolve(job)).to eq([
        candidate(provider: "codex"),
        candidate(provider: "claude"),
        candidate(provider: "agy")
      ])
    end

    it "still lets a repository-scoped routing rule override the repository's explicit provider for that task" do
      repository.update!(agent_provider: "codex")
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "ci_failure", candidates: [ { "provider" => "agy" } ])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "claude" } ])

      expect(resolve(job)).to eq([ candidate(provider: "agy") ])
    end

    it "gives a write-tier membership provider override the same precedence as repository.agent_provider" do
      member = Factories.user(agent_provider: "claude")
      repository.repository_memberships.create!(user: member, role: "write", agent_provider: "codex")
      job = Factories.job(repository: repository, user: member, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: member.id, task_key: "default", candidates: [ { "provider" => "claude" } ])

      expect(resolve(job)).to eq([
        candidate(provider: "codex"),
        candidate(provider: "claude")
      ])
    end

    it "deduplicates when the same provider appears from the repository's explicit default and a user rule" do
      repository.update!(agent_provider: "codex")
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "codex" }, { "provider" => "claude" } ])

      expect(resolve(job)).to eq([
        candidate(provider: "codex"),
        candidate(provider: "claude")
      ])
    end

    it "still lets user-scoped routing rules define the default/fallback routing when the repository has no explicit provider" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "claude" } ])

      expect(resolve(job)).to eq([ candidate(provider: "claude") ])
    end
  end

  describe "an empty candidates array on the winning rule" do
    it "falls through to the next precedence level instead of returning an empty list" do
      job = Factories.job(repository: repository, user: user, job_provider_setting: "default")

      ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "ci_failure", candidates: [])
      ProviderRoutingRule.create!(scope_type: "user", scope_id: user.id, task_key: "default", candidates: [ { "provider" => "agy" } ])

      expect(resolve(job)).to eq([ candidate(provider: "agy") ])
    end
  end
end
