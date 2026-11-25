module RuntimeImages
  module Builds
    # Operator-facing health of the build plane, derived from durable records
    # only. Reports whether builds are being admitted, whether any attempt is
    # stale (its lease lapsed or it outlived the runtime ceiling without the
    # reaper catching it), and what has been failing and why. Counts and error
    # codes only: no log text, hosts, or addresses.
    class Health
      Check = RuntimeImages::Health::Check
      WINDOW = 24.hours
      FAILURE_WARN_RATIO = 0.5
      FAILURE_MIN_SAMPLE = 5

      def initialize(now: Time.current)
        @now = now
      end

      def checks
        [ builder_check, queue_check, stale_attempt_check, orphan_check, failure_check, denial_check, quota_check ]
      end

      def snapshot
        {
          builder_registered: Builds.builder_available?,
          requests: RuntimeImageBuildRequest.group(:state).count,
          oldest_queued_seconds: oldest_queued_seconds,
          stale_attempts: stale_attempts.count,
          orphaned_requests: orphaned_requests.count,
          outcomes_24h: recent_results.group(:outcome).count,
          error_codes_24h: recent_results.where.not(error_code: nil).group(:error_code).count,
          network_denials_24h: network_denials,
          limits: { concurrency: Config.max_concurrent_builds, per_namespace: Config.max_concurrent_per_namespace,
                    max_attempts: Config.max_attempts, lease_seconds: Config.lease_duration.to_i,
                    max_attempt_seconds: Config.max_attempt_runtime.to_i },
          in_flight: in_flight_summary,
          recent_failures: recent_failures
        }
      end

      def stale_attempts
        RuntimeImageBuildAttempt.active.where(lease_expires_at: ..(@now - Config.stale_lease_grace))
                                .or(RuntimeImageBuildAttempt.overdue(@now - Config.stale_lease_grace))
      end

      def orphaned_requests
        RuntimeImageBuildRequest.in_flight.where.not(id: RuntimeImageBuildAttempt.active.select(:runtime_image_build_request_id))
      end

      def oldest_queued_seconds
        oldest = RuntimeImageBuildRequest.queued.where(cancel_requested_at: nil).minimum(:created_at)
        oldest && (@now - oldest).to_i
      end

      private

      def builder_check
        queued = RuntimeImageBuildRequest.queued.count
        return Check.new("build executor", :ok, "registered") if Builds.builder_available?
        return Check.new("build executor", :ok, "not registered (build plane is dark)") if queued.zero?

        Check.new("build executor", :warn, "#{queued} request(s) queued but no build executor is registered")
      end

      def queue_check
        age = oldest_queued_seconds
        return Check.new("build queue", :ok, "nothing waiting") if age.nil?
        return Check.new("build queue", :ok, "oldest waiting #{age}s") if age < Config.stuck_queue_after
        return Check.new("build queue", :warn, "oldest request has waited #{age}s; no executor registered") unless Builds.builder_available?

        Check.new("build queue", :warn, "oldest request has waited #{age}s; check the runtime_image_builds queue and dispatcher")
      end

      def stale_attempt_check
        count = stale_attempts.count
        return Check.new("stale build attempts", :ok, "none") if count.zero?

        Check.new("stale build attempts", :fail, "#{count} active attempt(s) past their lease or runtime ceiling; the dispatcher is not recovering them")
      end

      def orphan_check
        count = orphaned_requests.count
        return Check.new("orphaned build requests", :ok, "none") if count.zero?

        Check.new("orphaned build requests", :warn, "#{count} in-flight request(s) have no active attempt")
      end

      def failure_check
        results = recent_results.where.not(outcome: "canceled")
        total = results.count
        return Check.new("build failures", :ok, "#{total} build(s) in 24h") if total < FAILURE_MIN_SAMPLE

        failed = results.where(outcome: %w[failed rejected]).count
        return Check.new("build failures", :ok, "#{failed} of #{total} failed in 24h") if failed.fdiv(total) < FAILURE_WARN_RATIO

        Check.new("build failures", :warn, "#{failed} of #{total} builds failed in 24h")
      end

      def denial_check
        count = recent_attempts.where(error_code: "network_denied").count
        return Check.new("build network", :ok, "no builds failed on denied destinations in 24h") if count.zero?

        Check.new("build network", :warn, "#{count} build(s) failed on denied destinations in 24h; review the allowlist")
      end

      def quota_check
        count = recent_attempts.where(error_code: "quota_exhausted").count
        return Check.new("build quota", :ok, "no quota exhaustion in 24h") if count.zero?

        Check.new("build quota", :warn, "#{count} quota exhaustion(s) in 24h")
      end

      def recent_attempts = RuntimeImageBuildAttempt.where(finished_at: (@now - WINDOW)..)

      def recent_results = RuntimeImageBuildResult.where(finished_at: (@now - WINDOW)..)

      def network_denials
        RuntimeImageAuditEvent.since(@now - WINDOW).where(event_type: "build.network", outcome: "detected").count
      end

      def in_flight_summary
        RuntimeImageBuildRequest.in_flight.includes(:attempts).order(:id).limit(50).map do |request|
          attempt = request.attempts.reverse.find(&:active?)
          { request_id: request.id, state: request.state, attempt: attempt&.number, worker: attempt&.worker_hostname,
            started_at: attempt&.started_at, lease_expires_at: attempt&.lease_expires_at, cancel_requested: request.cancel_requested? }
        end
      end

      def recent_failures
        recent_results.where(outcome: %w[failed rejected]).order(finished_at: :desc).limit(25).map do |result|
          { request_id: result.runtime_image_build_request_id, outcome: result.outcome, error_code: result.error_code,
            message: result.message, attempts_used: result.attempts_used, finished_at: result.finished_at }
        end
      end
    end
  end
end
