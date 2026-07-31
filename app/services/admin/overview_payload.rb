module Admin
  class OverviewPayload
    def as_json(*)
      payload = {
        active_runs: {
          total:       Run.where(state: "running").count,
          by_trigger:  Run.where(state: "running").group(:trigger_kind).count
        },
        queued_runs: {
          total: Run.where(state: "queued").count
        },
        recent_failures_24h: {
          total:      Run.where(state: "failed").where("finished_at >= ?", 24.hours.ago).count,
          by_trigger: Run.where(state: "failed").where("finished_at >= ?", 24.hours.ago).group(:trigger_kind).count
        },
        github_rate_limits: low_rate_limit_users,
        github_api_blocked_users: blocked_github_api_users,
        provider_circuits: provider_circuits,
        agent_session_capture_rate: capture_rate_payload,
        data_root_disk_usage: data_root_disk_usage_payload,
        worker_data_root_usages: InstanceVersion.worker_data_root_usages,
        worker_health: worker_health_payload(sample_limit_per_host: 4),
        stuck: stuck_items
      }

      payload[:workers] = workers_payload
      payload[:recurring] = recurring_payload
      payload
    end

    def stuck_json
      { items: stuck_items }
    end

    private

    def low_rate_limit_users
      User.where("gh_rate_limit_remaining IS NOT NULL AND gh_rate_limit_limit > 0").select do |u|
        u.gh_rate_limit_remaining.to_f / u.gh_rate_limit_limit < 0.10
      end.map do |u|
        {
          email: u.email_address,
          remaining: u.gh_rate_limit_remaining,
          limit: u.gh_rate_limit_limit,
          resource: u.gh_rate_limit_resource
        }
      end
    end

    def blocked_github_api_users
      User.where.not(gh_api_blocked_at: nil).order(:email_address).map do |u|
        {
          id: u.id,
          email: u.email_address,
          blocked_at: u.gh_api_blocked_at,
          reason: u.gh_api_blocked_reason,
          rate_limit: {
            remaining: u.gh_rate_limit_remaining,
            limit: u.gh_rate_limit_limit,
            resource: u.gh_rate_limit_resource,
            reset_at: u.gh_rate_limit_reset_at,
            observed_at: u.gh_rate_limit_observed_at
          }
        }
      end
    end

    def provider_circuits
      ProviderCircuitBreaker.open_circuits.map(&:as_json)
    end

    def capture_rate_payload
      recent = Run.joins(:step)
                  .where(steps: { kind: ::Step::AGENTIC_KINDS })
                  .where(runs: { state: "succeeded" })
                  .where("runs.finished_at >= ?", 24.hours.ago)
      total = recent.count
      captured = recent.left_outer_joins(:claude_session)
                       .where.not(claude_sessions: { id: nil })
                       .count
      {
        total: total,
        captured: captured,
        rate: total.zero? ? nil : (captured.to_f / total).round(3)
      }
    end

    def data_root_disk_usage_payload
      # Prefer the most-full worker's own reported usage (multi-worker aware);
      # fall back to the single cached snapshot on single-worker / dev.
      InstanceVersion.worst_data_root&.data_root_usage_json || DataRootDiskUsage.current&.as_json
    end

    def worker_health_payload(sample_limit_per_host:)
      ::Admin::WorkerHealthPayload.new(sample_limit_per_host: sample_limit_per_host).as_json
    end

    def workers_payload
      total = SolidQueue::Process.where(kind: "Worker").count
      stale = SolidQueue::Process.where(kind: "Worker")
                                 .where("last_heartbeat_at < ?", 2.minutes.ago)
                                 .count
      { total: total, stale: stale }
    rescue ActiveRecord::StatementInvalid,
           ActiveRecord::ConnectionNotEstablished,
           ActiveRecord::ActiveRecordError
      { unreachable: true }
    end

    def recurring_payload
      overdue = []
      ::SolidQueue::RecurringTask.find_each do |task|
        last = ::SolidQueue::RecurringExecution.where(task_key: task.key)
                                               .order(run_at: :desc).first
        if last.nil?
          overdue << { key: task.key, age_seconds: nil, never_run: true }
        else
          age = Time.current - last.run_at
          overdue << { key: task.key, age_seconds: age.to_i } if age > 10.minutes
        end
      end
      { overdue: overdue }
    rescue ActiveRecord::StatementInvalid,
           ActiveRecord::ConnectionNotEstablished,
           ActiveRecord::ActiveRecordError
      { unreachable: true }
    end

    def stuck_items
      ::Admin::StuckItems.all.map { |item| ::Admin::StuckItemPayload.serialize(item: item) }
    end
  end
end
