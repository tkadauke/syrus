module Filters
  module Chips
    module Spending
      class EpicId < Base
        filter_name "epic_id"
        label "Epic"
        bucket :fk
        operators :is, :is_not, :is_one_of, :is_none_of, :is_set, :is_unset

        def apply
          relation = scope.joins(:job)
          case op
          when :is         then relation.where(jobs: { epic_id: value })
          when :is_not     then relation.where.not(jobs: { epic_id: value })
          when :is_one_of  then relation.where(jobs: { epic_id: Array(value) })
          when :is_none_of then relation.where.not(jobs: { epic_id: Array(value) })
          when :is_set     then relation.where.not(jobs: { epic_id: nil })
          when :is_unset   then relation.where(jobs: { epic_id: nil })
          else unsupported_op!
          end
        end
      end
    end
  end
end
