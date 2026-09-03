module Filters
  module Chips
    module AdminPlugins
      class Enabled < Base
        filter_name "enabled"
        label "Enabled"
        bucket :enum
        operators :is
        values({ value: "enabled", label: "Enabled" }, { value: "disabled", label: "Disabled" })

        def apply
          case value.to_s
          when "enabled" then scope.where(enabled: true)
          when "disabled" then scope.where(enabled: false)
          else unsupported_op!
          end
        end
      end
    end
  end
end
