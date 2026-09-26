module Filters
  module Chips
    module AdminQueue
      class ScheduledAt < Base
        filter_name "scheduled_at"
        label "Scheduled"
        bucket :date
        operators :before, :after, :between, :within_last, :more_than_ago, :is_set, :is_unset

        UNITS = {
          "minutes" => 1.minute,
          "hours" => 1.hour,
          "days" => 1.day,
          "weeks" => 1.week,
          "months" => 1.month
        }.freeze

        def apply
          col = "#{job_table}.#{quote(:scheduled_at)}"
          case op
          when :before then scope.where("#{col} <= ?", to_time(value))
          when :after then scope.where("#{col} >= ?", to_time(value))
          when :between
            range = Array(value)
            scope.where("#{col} BETWEEN ? AND ?", to_time(range.first), to_time(range.last))
          when :within_last then scope.where("#{col} >= ?", duration_for(value).ago)
          when :more_than_ago then scope.where("#{col} <= ?", duration_for(value).ago)
          when :is_set then scope.where("#{col} IS NOT NULL")
          when :is_unset then scope.where("#{col} IS NULL")
          else unsupported_op!
          end
        end

        private

        def job_table = scope.connection.quote_table_name(SolidQueue::Job.table_name)
        def quote(column) = scope.connection.quote_column_name(column)

        def to_time(raw)
          raw.respond_to?(:in_time_zone) ? raw.in_time_zone : Time.zone.parse(raw.to_s)
        end

        def duration_for(raw)
          spec = raw.is_a?(Hash) ? raw : {}
          n = Integer(spec["n"] || spec[:n] || 0)
          unit = (spec["unit"] || spec[:unit]).to_s
          UNITS.fetch(unit) * n
        end
      end
    end
  end
end
