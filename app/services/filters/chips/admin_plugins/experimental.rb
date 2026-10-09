module Filters
  module Chips
    module AdminPlugins
      class Experimental < Base
        filter_name "experimental"
        label "Experimental"
        bucket :enum
        operators :is
        values({ value: "experimental", label: "Experimental" }, { value: "stable", label: "Stable" })

        def apply
          case value.to_s
          when "experimental" then scope.where(experimental: true)
          when "stable" then scope.where(experimental: false)
          else unsupported_op!
          end
        end
      end
    end
  end
end
