module Filters
  module Chips
    module AdminPlugins
      class Category < EnumColumn
        filter_name "category"
        label "Category"
        column :category
        values(*Syrus::Plugin::Category::ENTRIES.map { |entry| { value: entry.key, label: entry.label } })
      end
    end
  end
end
