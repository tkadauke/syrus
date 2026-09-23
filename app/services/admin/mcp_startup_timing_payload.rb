module Admin
  # Latency distributions for the chat MCP startup lifecycle (see
  # McpStartupTiming): per-phase count/avg/p50/p95/max elapsed time since
  # the turn's earliest observed phase (normally agent_process_spawn), plus
  # a count of turns that started but never reached the final
  # first_assistant_message phase in the window -- a coarse "stuck startup"
  # health signal. Mixed into Admin::McpToolUsagePayload's response so it
  # rides the same admin page/route rather than needing a new one.
  class McpStartupTimingPayload
    DEFAULT_WINDOW = 7.days
    MAX_WINDOW = 90.days
    EVENT_FETCH_LIMIT = 20_000

    def initialize(params: {})
      @params = params
    end

    def as_json
      events = scoped_events
      {
        window: { start: window_start.iso8601, end: window_end.iso8601 },
        filters: { provider: provider, server_name: server_name },
        phase_latency: phase_latency_rows(events),
        turns_observed: turns(events).size,
        stalled_turns: stalled_turn_count(events)
      }
    end

    private

    attr_reader :params

    # Only "agent_process_spawn" and "server_name" carry a filterable
    # value on every phase of a turn -- most phases are turn-scoped
    # (no server_name) or sidecar-scoped (no provider), so filtering the
    # flat event scope directly would silently drop the turn-scoped phases
    # for a filtered turn. Find turns where *any* event matches, then keep
    # every event for those turns.
    def scoped_events
      events = base_scope.to_a
      return events if provider.blank? && server_name.blank?

      matching_turns = events.group_by(&:turn_key).select do |_turn_key, turn_events|
        (provider.blank? || turn_events.any? { |event| event.provider == provider }) &&
          (server_name.blank? || turn_events.any? { |event| event.server_name == server_name })
      end.keys.to_set

      events.select { |event| matching_turns.include?(event.turn_key) }
    end

    def base_scope
      McpStartupPhaseEvent.where(occurred_at: window_start..window_end).order(:occurred_at).limit(EVENT_FETCH_LIMIT)
    end

    def turns(events)
      events.group_by(&:turn_key)
    end

    def phase_latency_rows(events)
      samples = Hash.new { |hash, key| hash[key] = [] }
      turns(events).each_value do |turn_events|
        sorted = turn_events.sort_by(&:occurred_at)
        start_at = sorted.first.occurred_at
        sorted.each { |event| samples[event.phase] << ((event.occurred_at - start_at) * 1000.0) }
      end

      McpStartupTiming::PHASES.filter_map do |phase|
        durations = samples[phase]&.sort
        next if durations.blank?

        {
          phase: phase,
          count: durations.size,
          avg_ms: average(durations),
          p50_ms: percentile(durations, 50),
          p95_ms: percentile(durations, 95),
          max_ms: durations.last.round(1)
        }
      end
    end

    # A turn that started (has at least one recorded phase) but whose
    # events never include the terminal first_assistant_message phase --
    # i.e. it never reached the point of showing the operator a reply.
    def stalled_turn_count(events)
      turns(events).count { |_turn_key, turn_events| turn_events.none? { |event| event.phase == "first_assistant_message" } }
    end

    def average(values)
      return nil if values.blank?

      (values.sum / values.size).round(1)
    end

    def percentile(sorted_values, pct)
      return nil if sorted_values.blank?

      index = ((pct / 100.0) * (sorted_values.size - 1)).round
      sorted_values[index].round(1)
    end

    def provider
      @provider ||= params[:provider].to_s.strip.presence
    end

    def server_name
      @server_name ||= (params[:server_name] || params[:server]).to_s.strip.presence
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
  end
end
