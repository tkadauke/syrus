module Filters
  module Chips
    module Memories
      class Scope < EnumColumn
        filter_name "scope"
        label "Scope"
        column :scope
        values ChatMemory::SCOPE
      end
    end
  end
end
