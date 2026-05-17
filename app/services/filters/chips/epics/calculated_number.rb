module Filters
  module Chips
    module Epics
      class CalculatedNumber < Base
        bucket :number
        operators :equals, :not_equals, :greater_than, :less_than, :between

        private

        def apply_expression(expression)
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
      end
    end
  end
end
