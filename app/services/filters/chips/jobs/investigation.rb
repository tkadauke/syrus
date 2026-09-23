module Filters
  module Chips
    module Jobs
      # Job#investigation is a plain boolean column (set at creation time by
      # InvestigationJobs::Creator; see Job#investigation_launch?). This chip
      # lets operators filter the Jobs list directly for investigation Jobs,
      # following the same boolean-chip pattern as PinnedByMe/HasUnreadFeedback.
      class Investigation < Base
        filter_name "investigation"
        label "Investigation"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          case op
          when :is_true  then scope.where(investigation: true)
          when :is_false then scope.where(investigation: false)
          else unsupported_op!
          end
        end
      end
    end
  end
end
