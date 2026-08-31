module Filters
  module Chips
    module Spending
      class CreatedAt < DateColumn
        filter_name "created_at"
        label "Datetime"
        column :created_at
        operators :before, :after, :between, :within_last, :more_than_ago
        date_precision :datetime
      end
    end
  end
end
