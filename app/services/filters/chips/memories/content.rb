module Filters
  module Chips
    module Memories
      class Content < StringColumn
        filter_name "content"
        label "Content"
        column :content
      end
    end
  end
end
