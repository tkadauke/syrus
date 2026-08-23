module WorkUnits
  module PreemptionPolicies
    class Checkpoint
      def mode = :checkpoint
      def checkpoint? = true
      def resume_strategy = :checkpoint_resume
    end
  end
end
