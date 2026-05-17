module Filters
  module Chips
    module Jobs
      class Kind < Base
        filter_name "kind"
        label "Kind"
        bucket :enum
        operators :is, :is_not, :is_one_of, :is_none_of
        values(*Job::KINDS)

        def apply
          case op
          when :is        then scope.where(kind: value)
          when :is_not    then scope.where.not(kind: value)
          when :is_one_of then scope.where(kind: Array(value))
          when :is_none_of then scope.where.not(kind: Array(value))
          else unsupported_op!
          end
        end
      end
    end
  end
end
