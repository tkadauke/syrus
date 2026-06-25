module AppApi
  class SetupStatus
    NEXT_STEP_PATHS = {
      "configure_credentials" => "/credentials",
      "add_repository" => "/repositories/new",
      "start_first_chat" => "/onboarding"
    }.freeze

    def initialize(user)
      @user = user
    end

    def as_json(*)
      {
        state: state,
        next_step: next_step,
        next_step_path: NEXT_STEP_PATHS[next_step],
        first_admin: first_admin?,
        credentials_configured: credentials_configured?,
        repository_configured: repository_configured?,
        first_job_started: first_job_started?,
        first_successful_job_completed: first_successful_job_completed?,
        first_epic_created: first_epic_created?,
        first_epic_started: first_epic_started?,
        first_epic_landed: first_epic_landed?,
        onboarding_chat_started: onboarding_chat_started?,
        credential_status: credential_status,
        readiness: readiness,
        counts: counts
      }
    end

    private

    attr_reader :user

    def state
      return "first_successful_job" if first_successful_job_completed?
      return "credentials_only" if credentials_configured? && !repository_configured?
      return "repository_only" if repository_configured? && !credentials_configured?
      return "first_chat_started" if first_epic_started?
      return "ready_for_first_chat" if credentials_configured? && repository_configured?
      return "first_admin" if first_admin?

      "not_started"
    end

    def next_step
      return nil if first_successful_job_completed?
      return "configure_credentials" unless credentials_configured?
      return "add_repository" unless repository_configured?

      "start_first_chat"
    end

    def first_admin?
      user.admin? && User.order(:id).limit(1).pick(:id) == user.id
    end

    def credentials_configured?
      agent_credential_configured? && github_credential_configured?
    end

    def agent_credential_configured?
      user.agent_provider_configured?(user.agent_provider)
    end

    # Onboarding wants BOTH a personal access token and the GitHub App for
    # best results (PAT covers private clones / fallback; the App gives a bot
    # identity + independent rate limit). Both are required to finish the step.
    def github_credential_configured?
      github_token_configured? && github_app_configured?
    end

    def github_token_configured?
      user.github_token.present?
    end

    def github_app_configured?
      AppSetting.github_app_registered?
    end

    def repository_configured?
      active_repository_count.positive?
    end

    # Onboarding completes when the first Epic lands.
    def first_successful_job_completed?
      first_epic_landed?
    end

    def first_epic_landed?
      user.first_epic_landed?
    end

    def first_epic_started?
      user.first_epic_started?
    end

    def first_epic_created?
      user.first_epic_created?
    end

    def onboarding_chat_started?
      user.onboarding_chat_started?
    end

    def first_job_started?
      job_count.positive?
    end

    def credential_status
      {
        github: github_credential_configured?,
        # `github_pat` (not `github_token`) so this status blob never contains
        # the write-only secret's column name.
        github_pat: github_token_configured?,
        github_app: github_app_configured?,
        agent: agent_credential_configured?,
        active_agent_provider: user.agent_provider
      }
    end

    def readiness
      AppApi::ReadinessChecks.new(user).as_json
    end

    def counts
      {
        repositories: active_repository_count,
        jobs: job_count,
        successful_jobs: successful_job_count
      }
    end

    def active_repository_count
      @active_repository_count ||= user.repositories.active.count
    end

    def successful_job_count
      @successful_job_count ||= user.jobs
        .where(state: "closed", closure_reason: Job::SUCCESSFUL_CLOSURE_REASONS)
        .count
    end

    def job_count
      @job_count ||= user.jobs.count
    end
  end
end
