module Filters
  module Chips
    module AdminUsers
      class HasCodexToken < Base
        filter_name "has_codex_token"
        label "Codex credential"
        bucket :enum
        operators :is
        values({ value: "true", label: "Set" }, { value: "false", label: "Missing" })

        def apply
          if ActiveModel::Type::Boolean.new.cast(value)
            scope.where("codex_api_key IS NOT NULL OR codex_auth_json IS NOT NULL")
          else
            scope.where(codex_api_key: nil, codex_auth_json: nil)
          end
        end
      end
    end
  end
end
