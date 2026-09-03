module Filters
  module Chips
    module AgentMemory
      class Content < FullTextStringColumn
        filter_name "content"
        label "Content"
        column :content
      end
    end
  end
end
