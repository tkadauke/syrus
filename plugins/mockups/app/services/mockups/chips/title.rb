module Mockups
  module Chips
    class Title < Syrus::Host::Filters::Chips::FullTextStringColumn
      filter_name "title"
      label "Title"
      column :title
    end
  end
end
