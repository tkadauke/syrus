module Filters
  module Chips
    module SpawnedProcesses
      class WallTimeout < NumberColumn
        filter_name "wall_timeout_s"
        label "Wall timeout"
        column :wall_timeout_s
      end
    end
  end
end
