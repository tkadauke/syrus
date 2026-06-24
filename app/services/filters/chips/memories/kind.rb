module Filters
  module Chips
    module Memories
      class Kind < EnumColumn
        filter_name "kind"
        label "Kind"
        column :kind
        values ChatMemory::KIND
      end
    end
  end
end
