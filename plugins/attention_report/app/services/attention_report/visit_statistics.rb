module AttentionReport
  class VisitStatistics
    MIN_VISIT_MS = 3.seconds.in_milliseconds
    MAX_VISIT_MS = 30.minutes.in_milliseconds
    MERGE_GAP = 30.seconds
    MIN_SAMPLES = 5

    Visit = Data.define(:route_id, :subject, :started_at, :ended_at, :active_ms)

    def initialize(samples)
      @samples = samples
    end

    def as_json
      cleaned.group_by(&:route_id).transform_values do |visits|
        values = visits.map(&:active_ms).sort
        {
          sample_count: values.length,
          p50_active_ms: percentile(values, 50),
          p90_active_ms: percentile(values, 90),
          enough_data: values.length >= MIN_SAMPLES,
          estimate: false
        }
      end
    end

    def cleaned
      merged = @samples.order(:started_at, :id).each_with_object([]) do |sample, visits|
        next if sample.active_ms < MIN_VISIT_MS

        visit = Visit.new(
          route_id: sample.route_id,
          subject: sample.route_params.to_h.stringify_keys.sort.to_h,
          started_at: sample.started_at,
          ended_at: sample.ended_at,
          active_ms: [ sample.active_ms, MAX_VISIT_MS ].min
        )
        previous = visits.last
        if mergeable?(previous, visit)
          visits[-1] = Visit.new(
            route_id: previous.route_id,
            subject: previous.subject,
            started_at: previous.started_at,
            ended_at: [ previous.ended_at, visit.ended_at ].max,
            active_ms: [ previous.active_ms + visit.active_ms, MAX_VISIT_MS ].min
          )
        else
          visits << visit
        end
      end
      merged
    end

    private

    def mergeable?(previous, visit)
      previous && previous.route_id == visit.route_id && previous.subject == visit.subject &&
        visit.started_at <= previous.ended_at + MERGE_GAP
    end

    def percentile(values, rank)
      return { status: "not_enough_data", sample_count: values.length } if values.length < MIN_SAMPLES

      index = ((rank / 100.0) * values.length).ceil - 1
      { status: "available", value_ms: values.fetch(index), sample_count: values.length }
    end
  end
end
