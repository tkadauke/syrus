module Filters
  module Chips
    module AdminUsers
      class HasMuseToken < Base
        filter_name "has_muse_token"
        label "Muse credential"
        bucket :enum
        operators :is
        values({ value: "true", label: "Set" }, { value: "false", label: "Missing" })

        def apply
          ActiveModel::Type::Boolean.new.cast(value) ? scope.where.not(muse_api_key: nil) : scope.where(muse_api_key: nil)
        end
      end
    end
  end
end
