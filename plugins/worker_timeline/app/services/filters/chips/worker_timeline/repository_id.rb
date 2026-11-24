module Filters
  module Chips
    module WorkerTimeline
      class RepositoryId < Syrus::Host::Filters::Chips::FkColumn
        filter_name "repository_id"
        label "Repository"
        column :repository_id
        operators :is

        def apply
          relation = scope.joins(:job)
          case op
          when :is then relation.where(jobs: { repository_id: value })
          else unsupported_op!
          end
        end
      end
    end
  end
end
