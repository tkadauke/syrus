module Filters
  module Chips
    module ChatMessages
      class Mode < ChatSessionEnumColumn
        filter_name "mode"
        label "Mode"
        column :mode

        def self.values
          ChatSession::MODES
        end

        def apply
          handler = handlers.fetch(op) { unsupported_op! }
          handler.call
        end

        private

        def handlers
          {
            is: -> { session_scope.where("#{mode_expression} = ?", value.to_s) },
            is_not: -> { session_scope.where.not("#{mode_expression} = ?", value.to_s) },
            is_one_of: -> { session_scope.where("#{mode_expression} IN (?)", values) },
            is_none_of: -> { session_scope.where.not("#{mode_expression} IN (?)", values) },
            is_set: -> { session_scope.where.not(chat_sessions: { mode: nil }) },
            is_unset: -> { session_scope.where(chat_sessions: { mode: nil }) }
          }
        end

        def values
          Array(value).map(&:to_s)
        end

        def mode_expression
          Arel.sql("COALESCE(chat_sessions.mode, 'planning')")
        end
      end
    end
  end
end
