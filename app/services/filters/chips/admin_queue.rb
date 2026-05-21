module Filters
  module Chips
    module AdminQueue
      class QueueName < StringColumn
        filter_name "queue_name"
        label "Queue"
        column :queue_name
      end

      class JobClass < StringColumn
        filter_name "job_class"
        label "Job class"
        column :class_name
      end

      class FailedSince < Base
        filter_name "failed_since"
        label "Failed since"
        bucket :date
        operators :before, :after, :between, :within_last, :more_than_ago, :is_set, :is_unset

        def apply
          failed_scope = scope.joins(:failed_execution)
          col = "solid_queue_failed_executions.created_at"

          case op
          when :before then failed_scope.where("#{col} <= ?", to_time(value))
          when :after then failed_scope.where("#{col} >= ?", to_time(value))
          when :between
            range = Array(value)
            failed_scope.where(col => to_time(range.first)..to_time(range.last))
          when :within_last
            failed_scope.where(col => duration_for(value).ago..)
          when :more_than_ago
            failed_scope.where("#{col} <= ?", duration_for(value).ago)
          when :is_set then failed_scope
          when :is_unset then scope.left_outer_joins(:failed_execution).where(solid_queue_failed_executions: { id: nil })
          else unsupported_op!
          end
        end

        private

        def to_time(value)
          case value
          when Time, DateTime, ActiveSupport::TimeWithZone then value
          when Date then value.in_time_zone
          else Time.zone.parse(value.to_s)
          end
        end

        def duration_for(value)
          spec = value.is_a?(Hash) ? value : {}
          n = Integer(spec["n"] || spec[:n] || 0)
          unit_key = (spec["unit"] || spec[:unit]).to_s
          per = Filters::Chips::DateColumn::UNITS[unit_key] or raise ArgumentError, "unknown duration unit: #{unit_key.inspect}"
          per * n
        end
      end
    end
  end
end
