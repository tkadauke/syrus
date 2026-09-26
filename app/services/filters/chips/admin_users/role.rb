module Filters
  module Chips
    module AdminUsers
      class Role < EnumColumn
        filter_name "role"
        label "Role"
        column :role
        values User::ROLES
      end
    end
  end
end
