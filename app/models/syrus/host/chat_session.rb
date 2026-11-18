module Syrus
  module Host
    class ChatSession < ReadFacade
      wraps ::ChatSession

      def id = read(:id)
      def title = read(:title)
      def user = User.wrap(read(:user))
      def repository = Repository.wrap(read(:repository))
    end
  end
end
