module ScheduledTasks
  module FireHandlers
    class Base
      PR_PILEUP_POLICY = :pr_pileup_policy
      PR_BASED_AUTO_APPROVAL = :pr_based_auto_approval

      attr_reader :task

      def initialize(task)
        @task = task
      end

      def applicable_behaviors = []

      def fire!(now:)
        raise NotImplementedError
      end
    end
  end
end
