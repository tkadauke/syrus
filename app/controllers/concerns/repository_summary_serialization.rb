# The repository record shape shared by the repository detail payload and any
# plugin surface that renders a repository header -- the GitHub issues tab, for
# one. Extracted so a plugin does not have to duplicate it or reach into
# RepositoriesController's private methods.
module RepositorySummarySerialization
  extend ActiveSupport::Concern

  def repository_detail_json(repository)
    {
      id: repository.id,
      slug: repository.slug,
      owner: repository.owner,
      name: repository.name,
      default_branch: repository.default_branch,
      upstream_owner: repository.upstream_owner,
      upstream_name: repository.upstream_name,
      upstream_default_branch: repository.upstream_default_branch,
      upstream_slug: repository.upstream_slug,
      trigger_label: repository.trigger_label,
      polling_enabled: repository.polling_enabled?,
      archived: repository.archived?,
      agent_provider: repository.agent_provider,
      agent_provider_label: repository.agent_provider.present? ? agent_provider_label(repository.agent_provider) : nil,
      effective_agent_provider: repository.effective_agent_provider,
      effective_agent_provider_label: agent_provider_label(repository.effective_agent_provider),
      github_url: "https://github.com/#{repository.slug}",
      created_at: repository.created_at.iso8601,
      owner_user: owner_user_json(repository.user),
      github_rate_limit: github_rate_limit_json(repository.user),
      ci_health: repository.ci_health,
      grader_health: repository.grader_health,
      main_health: repository.main_health,
      landing_paused: repository_main_health_landing_paused?(repository),
      main_branch_health_enabled: repository.main_branch_health_enabled?,
      main_branch_repair_enabled: repository_main_branch_repair_enabled?(repository),
      main_branch_repair_blocks_work: repository_main_branch_repair_blocks_work?(repository),
      main_branch_repair_auto_approve: repository.main_branch_repair_auto_approve?,
      treat_grader_timeouts_as_failures: repository.treat_grader_timeouts_as_failures?,
      last_health_checked_sha: repository.last_health_checked_sha
    }
  end

  def agent_provider_label(provider)
    ::App::Presentation.agent_provider_label(provider)
  end

  def github_rate_limit_json(user)
    return nil unless user&.gh_rate_limit_observed_at

    {
      remaining: user.gh_rate_limit_remaining,
      limit: user.gh_rate_limit_limit,
      resource: user.gh_rate_limit_resource || "core",
      observed_at: user.gh_rate_limit_observed_at.iso8601
    }
  end

  def owner_user_json(user)
    return nil unless user

    {
      id: user.id,
      display_name: user.team_display_name,
      email_address: user.email_address,
      admin: user.admin?,
      profile_path: profile_path(user)
    }
  end

  def repository_main_health_landing_paused?(repository)
    repository.main_branch_health_enabled? && repository.landing_paused?
  end

  def repository_main_branch_repair_enabled?(repository)
    repository.main_branch_health_enabled? && repository.main_branch_repair_enabled?
  end

  def repository_main_branch_repair_blocks_work?(repository)
    repository.main_branch_health_enabled? && repository.main_branch_repair_blocks_work?
  end
end
