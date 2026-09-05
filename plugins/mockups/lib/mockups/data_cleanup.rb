module Mockups
  # Mockups index core PreviewPanels, so a panel or chat going away has to take
  # its index entry with it -- otherwise the list shows rows whose content
  # cannot be fetched.
  #
  # Installed with `always`: disabling the plugin stops new mockups being
  # recorded, it does not delete what an operator already published.
  module DataCleanup
    def self.install_into(scope)
      scope.effect("chat mockups") do
        Syrus::DataCleanup.register("ChatSession", "mockups.entries") do |chat_session|
          Mockups::Mockup.where(chat_session_id: chat_session.id).find_each(&:destroy)
        end
      end

      scope.effect("user mockups") do
        Syrus::DataCleanup.register("User", "mockups.entries") do |user|
          Mockups::Mockup.where(user_id: user.id).find_each(&:destroy)
        end
      end
    end
  end
end
