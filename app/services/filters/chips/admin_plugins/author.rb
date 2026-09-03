module Filters
  module Chips
    module AdminPlugins
      class Author < StringColumn
        filter_name "author"
        label "Author"
        column :author
      end
    end
  end
end
