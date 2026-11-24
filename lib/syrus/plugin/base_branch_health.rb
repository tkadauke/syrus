module Syrus
  module Plugin
    # Optional integration surface for a plugin that tracks the health of a
    # repository's base branch and repairs it. Core never names that plugin: the
    # dispatcher, reconciler, landing queue, polling and CI-repair code talk to
    # the BaseBranchHealth facade, which answers with safe "nothing known"
    # defaults when no provider is enabled.
    #
    # Providers expose (all class-level, all optional):
    #
    #   .monitoring_enabled?(repository)          => Boolean
    #   .poll_later(repository_id, manual:)       => enqueue a fresh health check
    #   .repair_job?(job)                         => Boolean
    #   .repair_job_implemented(job)              => React to a repair Job reaching review
    #   .repair_job_closed(job)                   => React to a repair Job closing
    #   .ensure_repair!(repository)               => Spawn a repair Job when warranted
    #   .health_changed!(repository)              => React to a changed health state
    #   .stuck_repair_job(repository, now:)       => Job or nil
    #   .checks                                   => relation of recorded health checks
    #   .concern_reports                          => relation of agent-filed concern reports
    module BaseBranchHealth
      def self.included(base) = base.extend(self)
    end
  end
end
