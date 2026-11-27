module Filters
  module Chips
    module WorkerTimeline
      class Window < Syrus::Host::Filters::Chips::DateColumn
        filter_name "window"
        label "Time window"
        column :started_at
        operators :within_last, :between
      end
    end
  end
end
