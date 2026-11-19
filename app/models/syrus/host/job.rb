module Syrus
  module Host
    class Job < ReadFacade
      wraps ::Job

      class << self
        def visible_to(user) = wrap_all(record_class.visible_to(user))
        alias accessible_to visible_to
      end

      def id = read(:id)
      def state = read(:state)
      def title = read(:title)
      def repository = Repository.wrap(read(:repository))
      def user = User.wrap(read(:user))
      def workflows = Workflow.wrap_all(read(:workflows))
    end
  end
end
