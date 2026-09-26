module Filters
  module Chips
    module SpawnedProcesses
      class ExitStatus < NumberColumn
        filter_name "exit_status"
        label "Exit status"
        column :exit_status
      end
    end
  end
end
