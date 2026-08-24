module Filters
  module Chips
    module AdminUsers
      class Admin < Base
        filter_name "admin"
        label "Admin"
        bucket :enum
        operators :is
        values({ value: "true", label: "Yes" }, { value: "false", label: "No" })

        def apply
          scope.where(global_role: ActiveModel::Type::Boolean.new.cast(value) ? "admin" : "user")
        end
      end
    end
  end
end
