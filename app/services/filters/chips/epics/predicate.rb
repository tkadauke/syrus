module Filters
  module Chips
    module Epics
      class Predicate < Base
        bucket :boolean
        operators :is_true, :is_false

        def apply
          case op
          when :is_true then scope.where(id: matching_ids)
          when :is_false then scope.where.not(id: matching_ids)
          else unsupported_op!
          end
        end

        private

        def matching_ids
          raise NotImplementedError, "#{self.class} must implement #matching_ids"
        end
      end
    end
  end
end
