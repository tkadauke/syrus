module Coworkers
  module DataCleanup
    def self.install_into(scope)
      scope.effect("owner coworkers") do
        Syrus::DataCleanup.register("User", "coworkers.owned") do |user|
          Coworkers::Coworker.where(owner_user_id: user.id).find_each(&:destroy)
        end
      end

      scope.effect("coworker chats") do
        Syrus::DataCleanup.register("ChatSession", "coworkers.chat_links") do |chat|
          Coworkers::Chat.where(chat_session_id: chat.id).find_each(&:destroy)
        end
      end
    end
  end
end
