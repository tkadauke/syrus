module Filters
  module Chips
    module WorkerTimeline
      class EpicId < FkColumn
        filter_name "epic_id"
        label "Epic"
        column :epic_id
        operators :is

        def apply
          relation = scope.joins(:job)
          case op
          when :is then relation.where(jobs: { epic_id: value })
          else unsupported_op!
          end
        end
      end
    end
  end
end
