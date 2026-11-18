module Syrus
  module Host
    class Run < ReadFacade
      wraps ::Run

      def id = read(:id)
      def state = read(:state)
      def workflow = Workflow.wrap(read(:workflow))
      def job = Job.wrap(read(:job))
    end
  end
end
