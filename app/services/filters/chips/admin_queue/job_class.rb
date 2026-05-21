module Filters
  module Chips
    module AdminQueue
      class JobClass < Base
        filter_name "job_class"
        label "Job class"
        bucket :string
        operators :contains, :is

        def apply
          case op
          when :contains
            scope.where("#{job_table}.#{quote(:class_name)} LIKE ? ESCAPE '\\'", "%#{escape_like(value)}%")
          when :is
            scope.where("#{job_table}.#{quote(:class_name)} = ?", value)
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

        def escape_like(input)
          input.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" }
        end
      end
    end
  end
end
