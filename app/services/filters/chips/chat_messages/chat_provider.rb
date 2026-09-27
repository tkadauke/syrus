module Filters
  module Chips
    module ChatMessages
      class ChatProvider < ChatSessionEnumColumn
        filter_name "chat_provider"
        label "Provider"
        column :chat_provider

        def self.values
          User.chat_providers
        end
      end
    end
  end
end
