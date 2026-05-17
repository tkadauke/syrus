module Filters
  module Chips
    module Epics
      class ChildJobCount < Base
        filter_name "child_job_count"
        label "Child Job count"
        bucket :number
        operators :equals, :not_equals, :greater_than, :less_than, :between

        def apply
          case op
          when :equals then scope.where(id: ids_for_count(value.to_i..value.to_i))
          when :not_equals then scope.where.not(id: ids_for_count(value.to_i..value.to_i))
          when :greater_than then scope.where(id: ids_for_sql("#{metric_sql} > ?", value.to_i))
          when :less_than then scope.where(id: ids_for_sql("#{metric_sql} < ?", value.to_i))
          when :between
            range = Array(value).map(&:to_i)
            scope.where(id: ids_for_count(range.first..range.last))
          else unsupported_op!
          end
        end

        private

        def ids_for_count(range)
          ids_for_sql("#{metric_sql} BETWEEN ? AND ?", range.begin, range.end)
        end

        def ids_for_sql(sql, *binds)
          scope.left_joins(:jobs).group("epics.id").having(sql, *binds).select(:id)
        end

        def metric_sql
          "COUNT(jobs.id)"
        end
      end
    end
  end
end
