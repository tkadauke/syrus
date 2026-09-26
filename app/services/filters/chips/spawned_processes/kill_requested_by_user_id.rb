module Filters
  module Chips
    module SpawnedProcesses
      class KillRequestedByUserId < FkColumn
        filter_name "kill_requested_by_user_id"
        label "Kill requested by"
        column :kill_requested_by_user_id
      end
    end
  end
end
