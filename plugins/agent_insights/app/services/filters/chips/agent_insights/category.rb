module Filters
  module Chips
    module AgentInsights
      class Category < Syrus::Host::Filters::Chips::StringColumn
        filter_name "category"
        label "Category"
        column :category
      end
    end
  end
end
