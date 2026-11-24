module Filters
  module Chips
    module AgentMemory
      class Scope < Syrus::Host::Filters::Chips::EnumColumn
        filter_name "scope"
        label "Scope"
        column :scope
        values ::AgentMemory::Entry::SCOPE
      end
    end
  end
end
