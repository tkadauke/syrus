module Filters
  module Chips
    module AdminInvitations
      class Email < StringColumn
        filter_name "email"
        label "Email"
        column :email_address
        operators :contains
      end
    end
  end
end
