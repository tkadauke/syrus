module Filters
  module Chips
    module SpawnedProcesses
      class SilentTimeout < NumberColumn
        filter_name "silent_timeout_s"
        label "Silent timeout"
        column :silent_timeout_s
      end
    end
  end
end
