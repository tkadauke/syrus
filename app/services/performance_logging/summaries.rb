module PerformanceLogging
  class Summaries
    TYPES = {
      slow_requests: PerformanceLogging::SLOW_REQUEST_EVENT,
      slow_jobs: PerformanceLogging::SLOW_JOB_EVENT,
      slow_phases: PerformanceLogging::SLOW_PHASE_EVENT,
      browser_traces: PerformanceLogging::BROWSER_TRACE_EVENT,
      slow_sql: PerformanceLogging::SLOW_SQL_EVENT
    }.freeze

    def self.call(events)
      TYPES.transform_values do |event_name|
        selected = events.select { |event| (event["event"] || event["event_name"]) == event_name }
        {
          count: selected.size,
          average_duration_ms: average(selected),
          max_duration_ms: selected.filter_map { |event| numeric_duration(event) }.max
        }
      end
    end

    def self.average(events)
      durations = events.filter_map { |event| numeric_duration(event) }
      return if durations.empty?

      (durations.sum / durations.size).round(1)
    end
    private_class_method :average

    def self.numeric_duration(event)
      Float(event["duration_ms"], exception: false)&.round(1)
    end
    private_class_method :numeric_duration
  end
end
