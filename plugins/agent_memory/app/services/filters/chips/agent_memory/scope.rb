module Filters
  module Chips
    module AgentMemory
      class Scope < EnumColumn
        filter_name "scope"
        label "Scope"
        column :scope
        values ::AgentMemory::Entry::SCOPE
      end
    end
  end
end
