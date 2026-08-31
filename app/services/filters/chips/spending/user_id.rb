module Filters
  module Chips
    module Spending
      class UserId < FkColumn
        filter_name "user_id"
        label "User"
        column :user_id
        typeahead true
      end
    end
  end
end
