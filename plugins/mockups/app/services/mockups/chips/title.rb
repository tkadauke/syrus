module Mockups
  module Chips
    class Title < Filters::Chips::FullTextStringColumn
      filter_name "title"
      label "Title"
      column :title
    end
  end
end
