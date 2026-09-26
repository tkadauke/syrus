module Filters
  module Chips
    module AdminInvitations
      class ExpiresAt < DateColumn
        filter_name "expires_at"
        label "Expires"
        column :expires_at
      end
    end
  end
end
