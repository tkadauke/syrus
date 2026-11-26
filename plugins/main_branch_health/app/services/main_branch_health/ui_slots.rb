module MainBranchHealth
  class UiSlots
    include Syrus::Host::UiSlot
    include Rails.application.routes.url_helpers

    def self.ui_slots(slot:, context:)
      case slot
      when "repository.settings"
        [
          {
            id: "main_branch_health.repository_settings",
            component: "main_branch_health/RepositorySettings",
            order: 10,
            cacheable: false
          }
        ]
      when "dashboard.banner"
        dashboard_banner(context)
      else
        []
      end
    end

    # Health-blocked repositories for the dashboard banner. Empty when none is
    # blocked, so the panel only exists while there is something to show.
    def self.dashboard_banner(context)
      user = context[:user]
      return [] unless user

      repositories = new.blocked_repositories_json(user)
      return [] if repositories.empty?

      [
        {
          id: "main_branch_health.dashboard_banner",
          component: "main_branch_health/HealthBanners",
          order: 10,
          cacheable: false,
          props: { repositories: repositories }
        }
      ]
    end

    def blocked_repositories_json(user)
      user.repositories.active.select { |repo| health_blocks_work?(repo) }.map do |repo|
        status = MainHealthChangedService.new(repo).repair_status
        {
          id: repo.id,
          slug: repo.slug,
          main_health: repo.main_health,
          ci_health: repo.ci_health,
          grader_health: repo.grader_health,
          landing_paused: repo.landing_paused?,
          main_branch_repair_blocks_work: repo.main_branch_repair_blocks_work?,
          repository_path: repository_path(repo),
          repair_path: "/api/v1/app/repositories/#{repo.id}/repair_main_branch",
          main_branch_repair: repair_json(status)
        }
      end
    end

    private

    def health_blocks_work?(repository)
      repository.main_branch_health_enabled? &&
        repository.main_branch_repair_blocks_work? &&
        repository.landing_paused? &&
        (repository.main_health_broken? || repository.main_health_inconclusive?)
    end

    def repair_json(status)
      {
        enabled: status[:enabled],
        failed_open_jobs_count: status[:failed_open_jobs_count],
        max_open_failed_jobs: status[:max_open_failed_jobs],
        blocked_reason: status[:blocked_reason],
        can_request: status[:can_request],
        can_spawn: status[:can_spawn],
        blocking_job: job_json(status[:blocking_job]),
        failed_jobs: status[:failed_jobs].map { |job| job_json(job) }
      }
    end

    def job_json(job)
      return nil unless job

      { id: job.id, slug: job.slug, state: job.state, title: job.title, job_path: job_path(job) }
    end
  end
end
