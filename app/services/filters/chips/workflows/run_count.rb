module Filters
  module Chips
    module Workflows
      class RunCount < Base
        filter_name "run_count"
        label "Run count"
        bucket :number
        operators :equals, :not_equals, :greater_than, :less_than, :between

        def apply
          expression = <<~SQL.squish
            (
              SELECT COUNT(*)
              FROM runs
              INNER JOIN steps ON steps.id = runs.step_id
              WHERE steps.workflow_id = #{quoted_workflows_table}.#{quoted_id_column}
            )
          SQL

          case op
          when :equals       then scope.where("#{expression} = ?", value)
          when :not_equals   then scope.where("#{expression} != ?", value)
          when :greater_than then scope.where("#{expression} > ?", value)
          when :less_than    then scope.where("#{expression} < ?", value)
          when :between
            range = Array(value)
            scope.where("#{expression} BETWEEN ? AND ?", range.first, range.last)
          else unsupported_op!
          end
        end

        private

        def quoted_workflows_table
          scope.connection.quote_table_name(scope.table_name)
        end

        def quoted_id_column
          scope.connection.quote_column_name(scope.model.primary_key)
        end
      end
    end
  end
end
