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
        totals: {
          calls: usages.count,
          errors: usages.where(error: true).count
        },
        top_tools: tool_rows(usages, order_by: :calls),
        error_rates: tool_rows(usages, order_by: :error_rate),
        surface_breakdown: surface_rows(usages),
        unused_advertised_tools: (advertised - used).sort
      }
    end

    private

    attr_reader :params

    def scoped_usages
      scope = McpToolUsage.in_window(window_start, window_end)
      scope = scope.where(surface: surface) if surface.present?
      scope
    end

    def surface
      value = params[:surface].to_s
      return value if McpToolUsage::SURFACES.include?(value)

      nil
    end

    def window_start
      @window_start ||= begin
        parsed = parse_time(params[:start] || params[:since])
        start_time = parsed || (window_end - DEFAULT_WINDOW)
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

    def limit
      value = params[:limit].to_i
      return 20 if value <= 0

      [ value, 100 ].min
    end
  end
end
