module Filters
  module Chips
    module Jobs
      # Free-text chip pinned by FilterBar into a "Search for X" suggestion.
      # Delegates to Job.search so the FULLTEXT/LIKE behavior stays defined
      # in exactly one place (mirrors Filters::Chips::AdminPlugins::Search).
      class Search < Base
        filter_name "search"
        label "Search"
        bucket :string
        operators :contains
        free_text_search true

        def apply
          case op
          when :contains then scope.merge(Job.search(value))
          else unsupported_op!
          end
        end
      end
    end
  end
end
