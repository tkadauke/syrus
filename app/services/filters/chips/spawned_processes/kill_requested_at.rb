module Filters
  module Chips
    module SpawnedProcesses
      class KillRequestedAt < DateColumn
        filter_name "kill_requested_at"
        label "Kill requested at"
        column :kill_requested_at
      end
    end
  end
end
