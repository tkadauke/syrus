module WorkIntents
  module Scopes
    class Base
      def initialize(intent)
        @intent = intent
      end

      # Jobs whose approval state gates this intent (WorkIntents::Gates::Approval).
      def jobs_requiring_approval
        raise NotImplementedError, "#{self.class} must implement #jobs_requiring_approval"
      end

      # The Job used to relaunch a Workflow for this intent when no live
      # Workflow/WorkUnit is available to read one from directly
      # (WorkUnits::Launcher.relaunch_context_for_intent!). +snapshot_members+
      # is the prior WorkUnit's member Jobs, preferred over a fresh query
      # since it reflects exactly what last ran.
      def representative_job(snapshot_members)
        raise NotImplementedError, "#{self.class} must implement #representative_job"
      end

      private

      attr_reader :intent
    end
  end
end
