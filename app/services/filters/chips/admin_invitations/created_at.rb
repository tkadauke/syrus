module Filters
  module Chips
    module AdminInvitations
      class CreatedAt < DateColumn
        filter_name "created_at"
        label "Created"
        column :created_at
      end
    end
  end
end
