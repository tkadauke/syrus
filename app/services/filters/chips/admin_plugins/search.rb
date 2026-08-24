module Filters
  module Chips
    module AdminPlugins
      # Free-text chip, standing in for the page's old plain search box.
      # Delegates to PluginRecord.search so the FULLTEXT/LIKE behavior
      # (MySQL MATCH ... AGAINST in production, LIKE fallback in
      # dev/test) stays defined in exactly one place.
      class Search < Base
        filter_name "search"
        label "Search"
        bucket :string
        operators :contains

        def apply
          case op
          when :contains then scope.merge(PluginRecord.search(value))
          else unsupported_op!
          end
        end
      end
    end
  end
end
