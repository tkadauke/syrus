module Syrus
  module Host
    class Workflow < ReadFacade
      wraps ::Workflow

      def id = read(:id)
      def state = read(:state)
      def job = Job.wrap(read(:job))
      def runs = Run.wrap_all(read(:runs))
    end
  end
end
