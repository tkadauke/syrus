module Admin
  class OverviewPayload
    STUCK_ITEMS_PER_PAGE = 50

    def initialize(params: {})
      @params = params
    end

    def as_json(*)
      PerformanceLogging.phase("admin_overview_payload") do
        payload = {
          active_runs: PerformanceLogging.phase("admin_overview.active_runs") {
            {
              total:       Run.where(state: "running").count,
              by_trigger:  Run.where(state: "running").group(:trigger_kind).count
            }
          },
          queued_runs: PerformanceLogging.phase("admin_overview.queued_runs") {
            {
              total: Run.where(state: "queued").count
            }
          },
          recent_failures_24h: PerformanceLogging.phase("admin_overview.recent_failures_24h") {
            {
              total:      Run.where(state: "failed").where("finished_at >= ?", 24.hours.ago).count,
              by_trigger: Run.where(state: "failed").where("finished_at >= ?", 24.hours.ago).group(:trigger_kind).count
            }
          },
          github_rate_limits: PerformanceLogging.phase("admin_overview.github_rate_limits") { low_rate_limit_users },
          github_api_blocked_users: PerformanceLogging.phase("admin_overview.github_api_blocked_users") { blocked_github_api_users },
          provider_circuits: PerformanceLogging.phase("admin_overview.provider_circuits") { provider_circuits },
          agent_session_capture_rate: PerformanceLogging.phase("admin_overview.capture_rate") { capture_rate_payload },
          data_root_disk_usage: PerformanceLogging.phase("admin_overview.data_root_disk_usage") { data_root_disk_usage_payload },
          worker_data_root_usages: PerformanceLogging.phase("admin_overview.worker_data_root_usages") { InstanceVersion.worker_data_root_usages },
          worker_health: PerformanceLogging.phase("admin_overview.worker_health") { worker_health_payload(sample_limit_per_host: 4) },
          resource_admission: PerformanceLogging.phase("admin_overview.resource_admission") { resource_admission_payload },
          chat_scoped_events: PerformanceLogging.phase("admin_overview.chat_scoped_events") { chat_scoped_events_payload },
          stuck: PerformanceLogging.phase("admin_overview.stuck_cache") { paginated_cached_stuck_items },
          stuck_pagination: PerformanceLogging.phase("admin_overview.stuck_pagination") { cached_stuck_pagination },
          stuck_snapshot: PerformanceLogging.phase("admin_overview.stuck_snapshot") { stuck_snapshot_payload }
        }

        payload[:workers] = PerformanceLogging.phase("admin_overview.workers") { workers_payload }
        payload[:recurring] = PerformanceLogging.phase("admin_overview.recurring") { recurring_payload }
        payload
      end
    end

    def stuck_json
      PerformanceLogging.phase("admin_stuck_payload") do
        items = stuck_items
        ::Admin::StuckItemsCache.write(items: items, captured_at: Time.current)
        {
          items: paginated_items(items),
          pagination: pagination_for(items)
        }
      end
    end

    private

    attr_reader :params

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
      ProviderCircuitBreaker.open_circuits.map do |decision|
        ProviderCircuitInspector.call(provider: decision.provider)
      end
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

    def chat_scoped_events_payload
      ::Admin::ChatScopedEventObservabilityPayload.new.as_json
    end

    def resource_admission_payload
      ::Admin::ResourceAdmissionDiagnosticsPayload.new.as_json
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
      @stuck_items ||= ::Admin::StuckItems.all.map { |item| ::Admin::StuckItemPayload.serialize(item: item) }
    end

    def paginated_stuck_items
      paginated_items(stuck_items)
    end

    def stuck_pagination
      pagination_for(stuck_items)
    end

    def cached_stuck_snapshot
      @cached_stuck_snapshot ||= ::Admin::StuckItemsCache.read
    end

    def cached_stuck_items
      cached_stuck_snapshot.items
    end

    def paginated_cached_stuck_items
      paginated_items(cached_stuck_items)
    end

    def cached_stuck_pagination
      pagination_for(cached_stuck_items)
    end

    def stuck_snapshot_payload
      cached_stuck_snapshot.as_json.except(:items)
    end

    def paginated_items(items)
      items.slice(stuck_offset_for(items), STUCK_ITEMS_PER_PAGE) || []
    end

    def pagination_for(items)
      total = items.size
      {
        page: stuck_page_for(items),
        per_page: STUCK_ITEMS_PER_PAGE,
        total: total,
        total_pages: total_pages_for(items),
        first_item: total.zero? ? 0 : stuck_offset_for(items) + 1,
        last_item: [ stuck_offset_for(items) + paginated_items(items).size, total ].min,
        previous_path: stuck_page_for(items) > 1 ? stuck_page_path(stuck_page_for(items) - 1) : nil,
        next_path: stuck_page_for(items) < total_pages_for(items) ? stuck_page_path(stuck_page_for(items) + 1) : nil
      }
    end

    def stuck_offset
      (stuck_page_for(stuck_items) - 1) * STUCK_ITEMS_PER_PAGE
    end

    def stuck_offset_for(items)
      (stuck_page_for(items) - 1) * STUCK_ITEMS_PER_PAGE
    end

    def stuck_page
      stuck_page_for(stuck_items)
    end

    def stuck_page_for(items)
      [ requested_stuck_page, total_pages_for(items) ].min
    end

    def requested_stuck_page
      @stuck_page ||= begin
        value = params.respond_to?(:[]) ? params[:page] : nil
        Integer(value.presence || 1)
      rescue ArgumentError, TypeError
        1
      end.clamp(1, Float::INFINITY)
    end

    def stuck_total_pages
      total_pages_for(stuck_items)
    end

    def total_pages_for(items)
      [ (items.size.to_f / STUCK_ITEMS_PER_PAGE).ceil, 1 ].max
    end

    def stuck_page_path(page)
      "/admin/stuck?page=#{page}"
    end
  end
end
