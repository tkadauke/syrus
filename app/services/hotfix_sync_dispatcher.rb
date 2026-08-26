# Entry point for the Story 5/5A (docs/plans/delivery-tracks-and-promotion.md)
# `main -> develop` hotfix-sync ref-movement workflow. Creates a synthetic
# anchor Job (kind: "direct", no GitHub issue — same pattern
# PromotionDispatcher/MainHealthChangedService/MaybeDeployJob use for
# repository-level, not-about-any-issue Workflows) and dispatches
# Workflows::HotfixSync for it through WorkUnits::Launcher, mirroring
# PromotionDispatcher.
#
# Called on demand from `PollHotfixSyncJob` once it detects the release
# branch has commits the development track doesn't have yet.
class HotfixSyncDispatcher
  def self.call!(repository:, user: nil, source_branch: nil, target_branch: nil, agent_provider: nil)
    new(
      repository: repository,
      user: user,
      source_branch: source_branch,
      target_branch: target_branch,
      agent_provider: agent_provider
    ).call!
  end

  # Whether a hotfix-sync anchor Job for this repository is already open
  # (queued/running/awaiting manual merge). Used by `PollHotfixSyncJob` to
  # avoid dispatching a duplicate sync workflow every poll tick while a
  # prior one is still in flight.
  def self.pending_for?(repository)
    repository.jobs.open_threads.joins(:workflows).where(workflows: { trigger_kind: "hotfix_sync" }).exists?
  end

  def initialize(repository:, user: nil, source_branch: nil, target_branch: nil, agent_provider: nil)
    @repository = repository
    @user = user || repository.user
    @source_branch = source_branch
    @target_branch = target_branch
    @agent_provider = agent_provider
  end

  def call!
    policy = DeliveryPolicy.for(repository: @repository)
    source = @source_branch.presence || policy.hotfix_sync_source_branch
    target = @target_branch.presence || policy.hotfix_sync_target_branch

    Job.transaction do
      job = Job.create!(
        user: @user,
        repository: @repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Sync #{source} into #{target}",
        issue_body: "Automated ref-movement hotfix sync of `#{source}` into `#{target}`.",
        agent_provider: @agent_provider.presence || @repository.effective_agent_provider,
        priority: "high"
      )

      workflow = WorkUnits::Launcher.instantiate(
        kind: "hotfix_sync",
        job: job,
        artifacts: { "hotfix_sync_source_branch" => source, "hotfix_sync_target_branch" => target },
        agent_provider: @agent_provider,
        source_type: "hotfix_sync_dispatcher"
      )
      WorkUnits::Launcher.start!(workflow)
    end
  end
end
