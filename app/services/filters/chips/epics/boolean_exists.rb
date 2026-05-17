module Filters
  module Chips
    module Epics
      class BooleanExists < Base
        bucket :boolean
        operators :is_true, :is_false

        private

        def apply_exists(sql, *binds)
          case op
          when :is_true  then scope.where(sql, *binds)
          when :is_false then scope.where.not(sql, *binds)
          else unsupported_op!
          end
        end
      end
    end
  end
end
