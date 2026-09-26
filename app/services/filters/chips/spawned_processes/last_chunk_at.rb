module Filters
  module Chips
    module SpawnedProcesses
      class LastChunkAt < DateColumn
        filter_name "last_chunk_at"
        label "Last chunk"
        column :last_chunk_at
      end
    end
  end
end
