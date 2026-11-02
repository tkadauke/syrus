require "rails_helper"

RSpec.describe ProviderRouting::LegacyProviderConversion do
  let(:owner) { Factories.user }
  let(:member) { Factories.user }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets") }

  def repo_row(repo = repository, provider: "codex")
    { id: repo.id, owner: repo.owner, name: repo.name, user_id: repo.user_id, agent_provider: provider }
  end

  def membership_row(repo = repository, user: member, role: "write", provider: "codex")
    { repository_id: repo.id, user_id: user.id, role: role, agent_provider: provider }
  end

  def convert(repository_rows: [], membership_rows: [], **options)
    described_class.call(repository_rows: repository_rows, membership_rows: membership_rows, **options)
  end

  it "converts a repository pin into a repository-scoped default fallback_order rule" do
    result = convert(repository_rows: [ repo_row ])

    rule = ProviderRoutingRule.find_by!(scope_type: "repository", scope_id: repository.id)
    expect(rule.user_id).to eq(owner.id)
    expect(rule.trigger).to eq("type" => "default")
    expect(rule.action).to eq("strategy" => "fallback_order", "candidates" => [ { "provider" => "codex" } ])
    expect(result.converted.size).to eq(1)
  end

  it "routes a converted repository to the same provider as the pin did" do
    owner.update!(agent_provider: "claude")
    convert(repository_rows: [ repo_row(provider: "codex") ])
    job = Factories.job(repository: repository, user: owner, job_provider_setting: "default")

    expect(ProviderRouting::Resolver.call(job: job, task_key: "implement").map(&:provider)).to eq([ "codex" ])
  end

  it "is idempotent" do
    2.times { convert(repository_rows: [ repo_row ], membership_rows: [ membership_row ]) }

    expect(ProviderRoutingRule.where(scope_type: "repository", scope_id: repository.id).count).to eq(1)
    expect(ProviderRoutingRule.where(scope_type: "user", scope_id: member.id).count).to eq(1)
  end

  it "skips a repository that already has its own default rule" do
    ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "default", candidates: [ { "provider" => "claude" } ])

    result = convert(repository_rows: [ repo_row ])

    expect(ProviderRoutingRule.where(scope_type: "repository", scope_id: repository.id).count).to eq(1)
    expect(result.skipped.first).to include("already has a default routing rule")
  end

  it "ignores blank pins" do
    result = convert(repository_rows: [ repo_row(provider: "") ], membership_rows: [ membership_row(provider: nil) ])

    expect(ProviderRoutingRule.count).to eq(0)
    expect(result.converted).to be_empty
  end

  it "does not convert the skipped tkadauke/syrus codex pin, and logs it" do
    syrus = Factories.repository(user: owner, owner: "tkadauke", name: "syrus")
    messages = []

    result = convert(repository_rows: [ repo_row(syrus, provider: "codex") ], logger: ->(message) { messages << message })

    expect(ProviderRoutingRule.where(scope_type: "repository", scope_id: syrus.id)).to be_empty
    expect(result.skipped.first).to include("tkadauke/syrus", "codex")
    expect(messages.join).to include("tkadauke/syrus")
  end

  it "still converts a non-codex pin for tkadauke/syrus" do
    syrus = Factories.repository(user: owner, owner: "tkadauke", name: "syrus")

    convert(repository_rows: [ repo_row(syrus, provider: "claude") ])

    expect(ProviderRoutingRule.where(scope_type: "repository", scope_id: syrus.id).count).to eq(1)
  end

  describe "memberships" do
    it "converts a write-tier pin into a repository-limited default rule on the member's user scope, placed first" do
      existing = ProviderRoutingRule.create!(scope_type: "user", scope_id: member.id, task_key: "default", candidates: [ { "provider" => "claude" } ])

      convert(membership_rows: [ membership_row ])

      rule = ProviderRoutingRule.where(scope_type: "user", scope_id: member.id).order(:position).first
      expect(rule.conditions).to eq("repository" => { "ids" => [ repository.id ] })
      expect(rule.action_candidates.map { |c| c["provider"] }).to eq([ "codex" ])
      expect(rule.position).to eq(1)
      expect(existing.reload.position).to eq(2)
    end

    it "routes the member to the pinned provider for that repository only" do
      member.update!(agent_provider: "claude")
      other_repo = Factories.repository(user: owner, owner: "acme", name: "other")
      convert(membership_rows: [ membership_row ])

      pinned = Factories.job(repository: repository, user: member, job_provider_setting: "default")
      elsewhere = Factories.job(repository: other_repo, user: member, job_provider_setting: "default")

      expect(ProviderRouting::Resolver.call(job: pinned, task_key: "implement").map(&:provider)).to eq([ "codex" ])
      expect(ProviderRouting::Resolver.call(job: elsewhere, task_key: "implement").map(&:provider)).to eq([ "claude" ])
    end

    it "ignores read-tier memberships, which never had an effect" do
      convert(membership_rows: [ membership_row(role: "read") ])

      expect(ProviderRoutingRule.count).to eq(0)
    end

    it "warns when repository rules will shadow the member override" do
      ProviderRoutingRule.create!(scope_type: "repository", scope_id: repository.id, task_key: "default", candidates: [ { "provider" => "claude" } ])

      result = convert(membership_rows: [ membership_row ])

      expect(result.warnings.first).to include("shadowed")
      expect(result.converted.size).to eq(1)
    end
  end
end
