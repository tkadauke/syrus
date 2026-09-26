module Filters
  module Chips
    module AgentInsights
      class HasMemorySuggestion < Base
        filter_name "has_memory_suggestion"
        label "Memory suggestion"
        bucket :boolean
        operators :is_true, :is_false

        def apply
          case op
          when :is_true
            scope.where.not(memory_suggestion: [ nil, "" ])
          when :is_false
            scope.where(memory_suggestion: [ nil, "" ])
          else
            unsupported_op!
          end
        end
      end
    end
  end
end
