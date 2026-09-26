module Filters
  module Chips
    module SpawnedProcesses
      class Workdir < StringColumn
        filter_name "workdir"
        label "Workdir"
        column :workdir
      end
    end
  end
end
