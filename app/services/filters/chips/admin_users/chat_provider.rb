module Filters
  module Chips
    module AdminUsers
      class ChatProvider < EnumColumn
        filter_name "chat_provider"
        label "Chat provider"
        column :chat_provider

        def self.values
          ChatProviders.provider_keys.sort
        end
      end
    end
  end
end
