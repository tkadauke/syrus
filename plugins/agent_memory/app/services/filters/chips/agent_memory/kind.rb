module Filters
  module Chips
    module AgentMemory
      class Kind < Syrus::Host::Filters::Chips::EnumColumn
        filter_name "kind"
        label "Kind"
        column :kind
        values ::AgentMemory::Entry::KIND
      end
    end
  end
end
