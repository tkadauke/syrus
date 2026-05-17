module Filters
  module Chips
    module Jobs
      class PinnedByMe < Base
        filter_name "pinned_by_me"
        label "Pinned by me"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          return scope unless user

          pinned = Job.joins(:job_pins).where(job_pins: { user_id: user.id }).select(:id)
          case op
          when :is_true  then scope.where(id: pinned)
          when :is_false then scope.where.not(id: pinned)
          else unsupported_op!
          end
        end
      end
    end
  end
end
