module Filters
  module Chips
    module SpawnedProcesses
      class ChatSessionId < Base
        filter_name "chat_session_id"
        label "Chat session ID"
        bucket :number
        operators :is

        def apply
          scope.where(chat_session_id: value)
        end
      end
    end
  end
end
