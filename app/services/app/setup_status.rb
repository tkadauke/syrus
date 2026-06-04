module App
  class SetupStatus
    SUCCESSFUL_CLOSURE_REASONS = %w[
      pr_merged
      external_pr_merged
      pr_approved
      no_changes
    ].freeze

    def self.call(user:)
      new(user).as_json
    end

    def initialize(user)
      @user = user
    end

    def as_json(*)
      {
        complete: complete?,
        next_step: next_step,
        progress: progress,
        credentials: credentials,
        system: system,
        github_app: github_app,
        repositories: repositories,
        first_job: first_job,
        paths: paths
      }
    end

    private

    attr_reader :user

    def complete?
      successful_first_job?
    end

    def next_step
      return "complete" if complete?
      return "credentials" unless credentials_ready?
      return "repository" unless active_repository?
      return "first_job" unless any_job?

      "watch_job"
    end

    def progress
      steps = [
        { key: "credentials", label: "Add credentials", complete: credentials_ready? },
        { key: "repository", label: "Add a repository", complete: active_repository? },
        { key: "first_job", label: "Start the first Job", complete: any_job? },
        { key: "watch_job", label: "Watch the first successful Job or PR", complete: successful_first_job? }
      ]

      {
        completed: steps.count { |step| step[:complete] },
        total: steps.length,
        steps: steps
      }
    end

    def credentials
      {
        github_token: user.github_token.present?,
        selected_agent_provider: user.agent_provider,
        selected_agent_provider_configured: user.agent_provider_configured?(user.agent_provider),
        configured_agent_providers: user.configured_agent_providers,
        ready: credentials_ready?
      }
    end

    def system
      {
        data_root: ENV.fetch("SYRUS_DATA_ROOT", "~/.syrus"),
        revision: ENV.fetch("GIT_SHA", "dev"),
        polling_paused: AppSetting.polling_paused?,
        runs_paused: AppSetting.runs_paused?,
        ready: !AppSetting.polling_paused? && !AppSetting.runs_paused?
      }
    end

    def github_app
      {
        registered: AppSetting.github_app_registered?,
        explanation: "Repositories use a GitHub App installation when one is active for that owner. Syrus falls back to your GitHub PAT for repositories without an active installation.",
        register_path: user.admin? && !AppSetting.github_app_registered? ? routes.admin_github_app_register_path : nil,
        installations_path: user.admin? ? routes.admin_installations_path : nil
      }
    end

    def repositories
      active = user.repositories.active.order(:owner, :name)
      {
        active_count: active.count,
        any_app_credential_active: active.any?(&:app_credential_active?),
        any_pat_fallback: active.any? { |repository| !repository.app_credential_active? },
        first: repository_payload(active.first)
      }
    end

    def first_job
      job = latest_job
      {
        any: job.present?,
        successful: successful_first_job?,
        job: job_payload(job)
      }
    end

    def paths
      {
        setup_path: routes.setup_path,
        credentials_path: routes.edit_credentials_path,
        new_repository_path: routes.new_repository_path,
        repositories_path: routes.repositories_path,
        new_job_path: routes.new_job_path,
        dashboard_jobs_path: routes.dashboard_jobs_path
      }
    end

    def credentials_ready?
      user.github_token.present? && user.agent_provider_configured?(user.agent_provider)
    end

    def active_repository?
      user.repositories.active.exists?
    end

    def any_job?
      user.jobs.exists?
    end

    def successful_first_job?
      user.jobs.where(closure_reason: SUCCESSFUL_CLOSURE_REASONS).exists?
    end

    def latest_job
      @latest_job ||= user.jobs.includes(:repository).order(updated_at: :desc, id: :desc).first
    end

    def repository_payload(repository)
      return nil unless repository

      {
        id: repository.id,
        slug: repository.slug,
        trigger_label: repository.trigger_label,
        credential_mode: repository.credential_mode,
        repository_path: routes.repository_path(repository),
        issues_path: routes.repository_path(repository, tab: "github_issues")
      }
    end

    def job_payload(job)
      return nil unless job

      {
        id: job.id,
        title: job.issue_title.presence || ::App::Presentation.job_slug(job),
        state: job.state,
        closure_reason: job.closure_reason,
        pr_number: job.pr_number || job.external_pr_number,
        repository_slug: job.repository.slug,
        job_path: routes.job_path(job)
      }
    end

    def routes
      Rails.application.routes.url_helpers
    end
  end
end
