module Filters
  module Chips
    module ChatMessages
      class ChatSessionEnumColumn < EnumColumn
        def apply
          handler = handlers.fetch(op) { unsupported_op! }
          handler.call(self.class.column)
        end

        private

        def handlers
          {
            is: ->(column) { session_scope.where(chat_sessions: { column => value }) },
            is_not: ->(column) { session_scope.where.not(chat_sessions: { column => value }) },
            is_one_of: ->(column) { session_scope.where(chat_sessions: { column => Array(value) }) },
            is_none_of: ->(column) { session_scope.where.not(chat_sessions: { column => Array(value) }) },
            is_set: ->(column) { session_scope.where.not(chat_sessions: { column => nil }) },
            is_unset: ->(column) { session_scope.where(chat_sessions: { column => nil }) }
          }
        end

        def session_scope
          scope.joins(:chat_session)
        end
      end
    end
  end
end
