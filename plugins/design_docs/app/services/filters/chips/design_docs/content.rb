module Filters
  module Chips
    module DesignDocs
      class Content < Syrus::Host::Filters::Chips::FullTextStringColumn
        filter_name "content"
        label "Content"
        column :markdown
      end
    end
  end
end
