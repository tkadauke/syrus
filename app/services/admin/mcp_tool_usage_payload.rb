module Admin
  class McpToolUsagePayload
    DEFAULT_WINDOW = 7.days
    MAX_WINDOW = 90.days

    def initialize(params: {})
      @params = params
    end

    def as_json
      usages = scoped_usages
      advertised = McpToolUsageRecorder.advertised_tools(surface: surface)
      used = usages.distinct.pluck(:normalized_tool_name)

      {
        window: {
          start: window_start.iso8601,
          end: window_end.iso8601
        },
        surface: surface.presence || "all",
        filters: {
          tool_name: tool_name,
          server_name: server_name
        },
        totals: {
          calls: usages.count,
          errors: usages.where(error: true).count
        },
        top_tools: tool_rows(usages, order_by: :calls),
        error_rates: tool_rows(usages, order_by: :error_rate),
        surface_breakdown: surface_rows(usages),
        provider_breakdown: provider_rows(usages),
        server_breakdown: server_rows(usages),
        sidecar_mode_breakdown: sidecar_mode_rows(usages),
        unused_advertised_tools: (advertised - used).sort,
        recent_calls: recent_call_rows(usages)
      }
    end

    private

    attr_reader :params

    def scoped_usages
      scope = McpToolUsage.in_window(window_start, window_end)
      scope = scope.where(surface: surface) if surface.present?
      scope = scope.where(normalized_tool_name: tool_name) if tool_name.present?
      scope = scope.where(server_name: server_name) if server_name.present?
      scope
    end

    def surface
      value = params[:surface].to_s
      return value if McpToolUsage::SURFACES.include?(value)

      nil
    end

    def tool_name
      @tool_name ||= normalized_filter_value(params[:tool_name] || params[:tool])
    end

    def server_name
      @server_name ||= normalized_filter_value(params[:server_name] || params[:server])
    end

    def normalized_filter_value(value)
      value.to_s.strip.presence
    end

    def window_start
      @window_start ||= begin
        explicit_start = parse_window_start(params[:start] || params[:since])
        start_time = explicit_start || (window_end - requested_window)
        [ start_time, window_end - MAX_WINDOW ].max
      end
    end

    def window_end
      @window_end ||= parse_time(params[:end] || params[:until]) || Time.current
    end

    def parse_time(value)
      return if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def parse_window_start(value)
      return if value.blank?

      duration = parse_duration(value)
      return window_end - duration if duration

      parse_time(value)
    end

    def requested_window
      parse_duration(params[:window]) || parse_duration(params[:window_preset]) || DEFAULT_WINDOW
    end

    def parse_duration(value)
      return if value.blank?

      match = value.to_s.strip.downcase.match(/\A(\d+)\s*([hdw])\z/)
      return unless match

      amount = match[1].to_i
      return if amount <= 0

      duration = case match[2]
      when "h" then amount.hours
      when "d" then amount.days
      when "w" then amount.weeks
      end
      [ duration, MAX_WINDOW ].min
    end

    def tool_rows(usages, order_by:)
      grouped = usages.group(:normalized_tool_name, :server_name)
                     .pluck(:normalized_tool_name, :server_name, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN error THEN 1 ELSE 0 END)"))

      rows = grouped.map do |tool_name, server_name, count, errors|
        errors = errors.to_i
        count = count.to_i
        {
          tool_name: tool_name,
          server_name: server_name,
          calls: count,
          errors: errors,
          error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0
        }
      end

      sorted = if order_by == :error_rate
        rows.sort_by { |row| [ -row[:error_rate], -row[:errors], row[:tool_name].to_s ] }
      else
        rows.sort_by { |row| [ -row[:calls], row[:tool_name].to_s ] }
      end
      sorted.first(limit)
    end

    def surface_rows(usages)
      usages.group(:surface)
            .pluck(:surface, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN error THEN 1 ELSE 0 END)"))
            .map do |surface, count, errors|
              count = count.to_i
              errors = errors.to_i
              {
                surface: surface,
                calls: count,
                errors: errors,
                error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0
              }
            end
            .sort_by { |row| row[:surface].to_s }
    end

    def provider_rows(usages)
      usages.group(:provider)
            .pluck(:provider, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN error THEN 1 ELSE 0 END)"))
            .map do |provider, count, errors|
              count = count.to_i
              errors = errors.to_i
              {
                provider: provider,
                calls: count,
                errors: errors,
                error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0
              }
            end
            .sort_by { |row| [ -row[:calls], row[:provider].to_s ] }
    end

    def server_rows(usages)
      usages.group(:server_name)
            .pluck(:server_name, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN error THEN 1 ELSE 0 END)"))
            .map do |server_name, count, errors|
              count = count.to_i
              errors = errors.to_i
              {
                server_name: server_name,
                calls: count,
                errors: errors,
                error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0
              }
            end
            .sort_by { |row| [ -row[:calls], row[:server_name].to_s ] }
    end

    # Stdio (transcript-derived) vs. persistent (PersistentMcpDaemon dispatch
    # boundary, EPIC-250) call/error volumes side by side, so tool
    # consolidation work can tell whether the persistent daemon path is
    # actually taking traffic and whether it fails more or less often than
    # stdio. `sidecar_mode` is nil on rows recorded before this column
    # existed; those are grouped separately rather than folded into "stdio"
    # so historical gaps stay visible instead of silently misattributed.
    def sidecar_mode_rows(usages)
      usages.group(:sidecar_mode)
            .pluck(:sidecar_mode, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN error THEN 1 ELSE 0 END)"))
            .map do |sidecar_mode, count, errors|
              count = count.to_i
              errors = errors.to_i
              {
                sidecar_mode: sidecar_mode,
                calls: count,
                errors: errors,
                error_rate: count.positive? ? (errors.to_f / count).round(4) : 0.0
              }
            end
            .sort_by { |row| row[:sidecar_mode].to_s }
    end

    def limit
      value = params[:limit].to_i
      return 20 if value <= 0

      [ value, 100 ].min
    end

    # Individual call rows for operators tracing a specific failure or
    # deciding whether a tool is actually reached from the surfaces it
    # claims to serve. Never includes raw tool input/result -- only the
    # bounded, already-truncated `error_message_summary` McpToolUsageRecorder
    # stores -- and links back to the originating Job/Workflow/Run/chat
    # instead of duplicating their data.
    def recent_call_rows(usages)
      usages.includes(:job, :run, :chat_session, workflow: :job)
            .order(created_at: :desc)
            .limit(recent_limit)
            .map { |usage| recent_call_row(usage) }
    end

    def recent_call_row(usage)
      {
        id: usage.id,
        occurred_at: (usage.completed_at || usage.started_at || usage.created_at).iso8601,
        surface: usage.surface,
        provider: usage.provider,
        tool_name: usage.tool_name,
        server_name: usage.server_name,
        status: usage.status,
        error: usage.error,
        error_class: usage.error_class,
        error_message_summary: usage.error_message_summary,
        sidecar_mode: usage.sidecar_mode,
        job_id: usage.job_id,
        job_path: usage.job_id ? "/jobs/#{usage.job_id}" : nil,
        workflow_id: usage.workflow_id,
        workflow_path: usage.workflow ? App::WorkflowNavigation.path(usage.workflow) : nil,
        run_id: usage.run_id,
        run_path: usage.run_id ? "/admin/runs/#{usage.run_id}/transcript" : nil,
        chat_session_id: usage.chat_session_id,
        chat_path: usage.chat_session_id ? "/chats/#{usage.chat_session_id}" : nil
      }
    end

    def recent_limit
      value = params[:recent_limit].to_i
      return 25 if value <= 0

      [ value, 100 ].min
    end
  end
end
