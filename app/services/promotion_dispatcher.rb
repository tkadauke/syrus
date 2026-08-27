# On-demand entry point for the Story 2 (docs/plans/delivery-tracks-and-promotion.md)
# `develop -> main` promotion ref-movement workflow. Creates a synthetic
# anchor Job (kind: "direct", no GitHub issue — same pattern
# MainHealthChangedService/MaybeDeployJob use for repository-level,
# not-about-any-issue Workflows) and dispatches Workflows::Promotion for it
# through WorkUnits::Launcher, same as MaybeDeployJob/MainGraderWorkflowJob.
#
# No scheduler yet — the parent issue leaves manual-vs-scheduled-vs-automatic
# triggering as an open question for a later Job. This is the "on-demand via
# a new service" entry point; wiring an MCP/chat/admin-UI trigger on top of
# it is future work.
class PromotionDispatcher
  def self.call!(repository:, user: nil, source_branch: nil, target_branch: nil, agent_provider: nil)
    new(
      repository: repository,
      user: user,
      source_branch: source_branch,
      target_branch: target_branch,
      agent_provider: agent_provider
    ).call!
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
    source = @source_branch.presence || policy.promotion_source_branch
    target = @target_branch.presence || policy.promotion_target_branch

    Job.transaction do
      job = Job.create!(
        user: @user,
        repository: @repository,
        kind: "direct",
        issue_number: nil,
        issue_title: "Promote #{source} into #{target}",
        issue_body: "Automated ref-movement promotion of `#{source}` into `#{target}`.",
        agent_provider: @agent_provider.presence || @repository.effective_agent_provider,
        priority: "high"
      )

      workflow = WorkUnits::Launcher.instantiate(
        kind: "promotion",
        job: job,
        artifacts: { "promotion_source_branch" => source, "promotion_target_branch" => target },
        agent_provider: @agent_provider,
        source_type: "promotion_dispatcher"
      )
      WorkUnits::Launcher.start!(workflow)
    end
  end
end
