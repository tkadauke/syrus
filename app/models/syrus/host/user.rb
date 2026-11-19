module Syrus
  module Host
    class User < ReadFacade
      wraps ::User

      def id = read(:id)
      def handle = read(:handle)
      def display_name = read(:display_name)
      def admin? = read(:admin?)
      def repositories = Repository.wrap_all(read(:repositories))
      def jobs = Job.wrap_all(read(:jobs))
    end
  end
end
