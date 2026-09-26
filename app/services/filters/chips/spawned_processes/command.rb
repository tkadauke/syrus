module Filters
  module Chips
    module SpawnedProcesses
      class Command < StringColumn
        filter_name "command"
        label "Command"
        column :command
      end
    end
  end
end
