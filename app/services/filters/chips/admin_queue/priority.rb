module Filters
  module Chips
    module AdminQueue
      class Priority < Base
        filter_name "priority"
        label "Priority"
        bucket :number
        operators :equals, :not_equals, :greater_than, :less_than, :between

        def apply
          col = "#{job_table}.#{quote(:priority)}"
          case op
          when :equals then scope.where("#{col} = ?", value)
          when :not_equals then scope.where("#{col} != ?", value)
          when :greater_than then scope.where("#{col} > ?", value)
          when :less_than then scope.where("#{col} < ?", value)
          when :between
            bounds = Array(value)
            scope.where("#{col} BETWEEN ? AND ?", bounds.first, bounds.last)
          else unsupported_op!
          end
        end

        private

        def job_table = scope.connection.quote_table_name(SolidQueue::Job.table_name)
        def quote(column) = scope.connection.quote_column_name(column)
      end
    end
  end
end
