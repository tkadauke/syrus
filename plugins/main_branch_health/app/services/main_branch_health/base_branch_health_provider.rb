module MainBranchHealth
  # The :base_branch_health provider: the answers core's BaseBranchHealth
  # facade asks of this plugin.
  class BaseBranchHealthProvider
    include Syrus::Host::BaseBranchHealth

    def self.monitoring_enabled?(repository) = repository.main_branch_health_enabled?

    def self.poll_later(repository_id, manual: false)
      if manual
        PollMainBranchHealthJob.perform_later(repository_id, manual: true)
      else
        PollMainBranchHealthJob.perform_later(repository_id)
      end
    end

    def self.repair_job?(job) = MainHealthChangedService.fix_main_job?(job)

    def self.repair_job_implemented(job)
      MainBranchRepairAutoApprover.call(job) if job.main_branch_repair?
    end

    def self.repair_job_closed(job)
      return unless job.main_branch_repair?

      if job.closure_reason.in?(%w[pr_merged external_pr_merged])
        MainHealthChangedService.repair_landed!(job.repository, job: job)
      else
        MainHealthChangedService.ensure_repair_job!(job.repository)
      end
    end

    def self.ensure_repair!(repository) = MainHealthChangedService.ensure_repair_job!(repository)

    def self.health_changed!(repository) = MainHealthChangedService.on_health_change!(repository)

    def self.stuck_repair_job(repository, now: Time.current)
      MainHealthChangedService.new(repository).stuck_blocking_repair_job(now: now)
    end

    def self.settled_ci_health = MainBranchHealthCheck::SETTLED_CI_HEALTH

    def self.checks = MainBranchHealthCheck

    def self.concern_reports = MainConcernReport
  end
end
