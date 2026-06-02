module AppApi
  class SetupStatus
    NEXT_STEP_PATHS = {
      "configure_credentials" => "/credentials/edit",
      "add_repository" => "/repositories/new",
      "start_first_job" => "/jobs/new"
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
        first_successful_job_completed: first_successful_job_completed?,
        credential_status: credential_status,
        counts: counts
      }
    end

    private

    attr_reader :user

    def state
      return "first_successful_job" if first_successful_job_completed?
      return "credentials_only" if credentials_configured? && !repository_configured?
      return "repository_only" if repository_configured? && !credentials_configured?
      return "ready_for_first_job" if credentials_configured? && repository_configured?
      return "first_admin" if first_admin?

      "not_started"
    end

    def next_step
      return nil if first_successful_job_completed?
      return "configure_credentials" unless credentials_configured?
      return "add_repository" unless repository_configured?

      "start_first_job"
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

    def github_credential_configured?
      user.github_token.present? || AppSetting.github_app_registered?
    end

    def repository_configured?
      active_repository_count.positive?
    end

    def first_successful_job_completed?
      successful_job_count.positive?
    end

    def credential_status
      {
        github: github_credential_configured?,
        agent: agent_credential_configured?,
        active_agent_provider: user.agent_provider
      }
    end

    def counts
      {
        repositories: active_repository_count,
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
  end
end
