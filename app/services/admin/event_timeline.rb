module Admin
  class EventTimeline
    MAX_BUCKETS = 48

    def self.build(scope, since_time:, until_time:)
      new(scope, since_time: since_time, until_time: until_time).as_json
    end

    def initialize(scope, since_time:, until_time:)
      @scope = scope
      @since_time = since_time || 24.hours.ago
      @until_time = until_time || Time.current
    end

    def as_json(*)
      rows_by_key = grouped_counts.index_by { |row| row.fetch("bucket") }
      bucket_starts.map do |start_time|
        key = bucket_key(start_time)
        {
          start_at: start_time.iso8601,
          end_at: [ start_time + bucket_size, until_time ].min.iso8601,
          count: rows_by_key.fetch(key, {}).fetch("count", 0)
        }
      end
    end

    private

    attr_reader :scope, :since_time, :until_time

    def grouped_counts
      scope
        .where(occurred_at: since_time..until_time)
        .unscope(:order)
        .group(bucket_sql)
        .count
        .map { |bucket, count| { "bucket" => bucket.to_s, "count" => count } }
    end

    def bucket_starts
      starts = []
      current = since_time.change(sec: 0)
      current -= current.to_i % bucket_size.to_i
      while current < until_time && starts.size < MAX_BUCKETS
        starts << current
        current += bucket_size
      end
      starts
    end

    def bucket_sql
      adapter = ActiveRecord::Base.connection.adapter_name.downcase
      seconds = bucket_size.to_i
      if adapter.include?("mysql")
        "FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(occurred_at) / #{seconds}) * #{seconds})"
      else
        "datetime((strftime('%s', occurred_at) / #{seconds}) * #{seconds}, 'unixepoch')"
      end
    end

    def bucket_key(time)
      adapter = ActiveRecord::Base.connection.adapter_name.downcase
      adapter.include?("mysql") ? time.strftime("%Y-%m-%d %H:%M:%S") : time.utc.strftime("%Y-%m-%d %H:%M:%S")
    end

    def bucket_size
      @bucket_size ||= begin
        span = until_time - since_time
        seconds = (span / MAX_BUCKETS).ceil
        if seconds <= 5.minutes
          5.minutes
        elsif seconds <= 15.minutes
          15.minutes
        elsif seconds <= 1.hour
          1.hour
        elsif seconds <= 6.hours
          6.hours
        else
          1.day
        end
      end
    end
  end
end
