module ProviderRouting
  # Usage-window producers (AgentProviders::Claude#usage_windows,
  # AgentProviders::Base#usage_windows) disagree on key types: the outer
  # "five_hour"/"weekly" window name is always a String, but the inner
  # per-window hash uses Symbol keys (`reset_at:`, `label:`, ...). A caller
  # that only tries one key type on both levels (e.g. `dig(:five_hour,
  # :reset_at)` or `dig("five_hour", "reset_at")`) silently gets `nil` even
  # though the value is present. This module is the single place that knows
  # the real shape, and normalizes reset_at to a zoned Time so a producer
  # using a different value type can never make `.min` raise, and so
  # `.iso8601` renders consistently (a bare `Time`/`DateTime` would render
  # its own UTC offset as "+00:00" instead of "Z").
  module UsageWindows
    WINDOW_KEYS = %w[five_hour weekly].freeze

    module_function

    def earliest_reset_at(usage)
      windows = usage[:windows] || usage["windows"] || {}

      WINDOW_KEYS.flat_map { |key| [ windows[key], windows[key.to_sym] ] }
        .compact
        .filter_map { |window| normalize_time(window[:reset_at] || window["reset_at"]) }
        .min
    end

    def normalize_time(value)
      case value
      when ActiveSupport::TimeWithZone then value
      when Time, DateTime then value.in_time_zone
      when String then Time.zone.parse(value)
      end
    rescue ArgumentError, TypeError
      nil
    end
  end
end
