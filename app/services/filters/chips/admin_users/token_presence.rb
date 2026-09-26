module Filters
  module Chips
    module AdminUsers
      class TokenPresence < Base
        bucket :enum
        operators :is
        values({ value: "true", label: "Set" }, { value: "false", label: "Missing" })

        def apply
          has_token? ? present_scope : missing_scope
        end

        private

        def has_token?
          ActiveModel::Type::Boolean.new.cast(value)
        end

        def present_scope
          raise NotImplementedError
        end

        def missing_scope
          raise NotImplementedError
        end
      end
    end
  end
end
