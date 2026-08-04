module Filters
  module Chips
    module AdminQueue
      class QueueName < Base
        filter_name "queue_name"
        label "Queue"
        bucket :enum
        operators :is, :is_one_of
        values "runs",
          "merges",
          "chat",
          "videos",
          "control_plane",
          "polling",
          "indexing",
          "cleanup",
          "low_priority_maintenance"

        def apply
          case op
          when :is
            scope.where("#{job_table}.#{quote(:queue_name)} = ?", value)
          when :is_one_of
            scope.where("#{job_table}.#{quote(:queue_name)} IN (?)", Array(value))
          else
            unsupported_op!
          end
        end

        private

        def job_table
          @job_table ||= scope.connection.quote_table_name(SolidQueue::Job.table_name)
        end

        def quote(column)
          scope.connection.quote_column_name(column)
        end
      end
    end
  end
end
