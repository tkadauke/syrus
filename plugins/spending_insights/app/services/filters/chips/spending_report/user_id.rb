module Filters
  module Chips
    module SpendingReport
      class UserId < Syrus::Host::Filters::Chips::FkColumn
        filter_name "user_id"
        label "User"
        column :user_id
      end
    end
  end
end
