module Filters
  module Chips
    module SpawnedProcesses
      class Kind < EnumColumn
        filter_name "kind"
        label "Kind"
        column :kind
        operators :is, :is_one_of
        values SpawnedProcess::KINDS
      end
    end
  end
end
