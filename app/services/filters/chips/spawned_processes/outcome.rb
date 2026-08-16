module Filters
  module Chips
    module SpawnedProcesses
      # How a finished subprocess ended. Distinct from `state`, which only
      # answers running-vs-finished — an outcome is nil until the process is
      # finalized.
      class Outcome < EnumColumn
        filter_name "outcome"
        label "Outcome"
        column :outcome
        operators :is, :is_one_of
        values SpawnedProcess::OUTCOMES
      end
    end
  end
end
