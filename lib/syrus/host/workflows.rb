require "forwardable"

module Syrus
  module Host
    # Workflow queries. Scheduling, transitions, and persistence are not
    # promised.
    module Workflows
      extend SingleForwardable

      def_delegators "::Workflow", :all, :where, :joins, :find, :resume_queue_name
    end
  end
end
